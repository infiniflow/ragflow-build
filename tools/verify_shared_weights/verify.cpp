// verify.cpp -- Proof-of-concept for in-process shared ONNX Runtime weights.
//
// Flow:
//   1. Load a .ort model into a reference session.
//   2. Enumerate its constant initializers via the custom C API
//      (SessionGetInitializerCount / Name / GetInitializer).
//   3. Inject every initializer into ONE shared OrtSessionOptions via the
//      existing AddInitializer C API.
//   4. Create N sessions from that shared options -> they reference the single
//      copied weight set instead of deserializing it N times.
//   5. Run the same input through the reference session and the N shared
//      sessions; assert outputs are bitwise identical.
//   6. Print process RSS before/after creating the N shared sessions to show
//      weights are shared (memory does not scale with N).
//
// Build against the patched libonnxruntime.a (see build.sh).

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cmath>
#include <unistd.h>
#include <string>
#include <vector>

#include "onnxruntime_c_api.h"

static const OrtApi* g_api = nullptr;

#define CHECK(status)                                                     \
  do {                                                                   \
    OrtStatus* _s = (status);                                            \
    if (_s != nullptr) {                                                 \
      fprintf(stderr, "ORT error @ %s:%d: %s\n", __FILE__, __LINE__,     \
              g_api->GetErrorMessage(_s));                               \
      g_api->ReleaseStatus(_s);                                          \
      exit(1);                                                           \
    }                                                                     \
  } while (0)

// Read resident set size in KiB from /proc/self/statm (Linux only).
static long read_rss_kib() {
  FILE* f = fopen("/proc/self/statm", "r");
  if (!f) return -1;
  long total_pages = 0, resident_pages = 0;
  // statm: total vmsize pages, resident pages, ...
  if (fscanf(f, "%ld %ld", &total_pages, &resident_pages) != 2) {
    fclose(f);
    return -1;
  }
  fclose(f);
  long page_kib = sysconf(_SC_PAGESIZE) / 1024;
  return resident_pages * page_kib;
}

// Create an float32 CPU tensor of `shape` filled with `data`.
static OrtValue* MakeFloatTensor(OrtAllocator* alloc, const std::vector<int64_t>& shape,
                                 const std::vector<float>& data) {
  OrtValue* v = nullptr;
  CHECK(g_api->CreateTensorAsOrtValue(alloc, shape.data(), shape.size(),
                                      ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &v));
  float* dst = nullptr;
  CHECK(g_api->GetTensorMutableData(v, reinterpret_cast<void**>(&dst)));
  memcpy(dst, data.data(), data.size() * sizeof(float));
  return v;
}

// Copy float output of an OrtValue into `out`.
static void ReadFloatOutput(OrtValue* out_val, std::vector<float>& out) {
  OrtTensorTypeAndShapeInfo* info = nullptr;
  CHECK(g_api->GetTensorTypeAndShape(out_val, &info));
  size_t count = 0;
  CHECK(g_api->GetTensorShapeElementCount(info, &count));
  g_api->ReleaseTensorTypeAndShapeInfo(info);
  const float* p = nullptr;
  CHECK(g_api->GetTensorMutableData(const_cast<OrtValue*>(out_val),
                                    reinterpret_cast<void**>(const_cast<float**>(&p))));
  out.assign(p, p + count);
}

static std::vector<int64_t> GetInputShape(OrtSession* sess) {
  OrtAllocator* alloc = nullptr;
  CHECK(g_api->GetAllocatorWithDefaultOptions(&alloc));
  char* name = nullptr;
  CHECK(g_api->SessionGetInputName(sess, 0, alloc, &name));

  OrtTypeInfo* ti = nullptr;
  CHECK(g_api->SessionGetInputTypeInfo(sess, 0, &ti));
  const OrtTensorTypeAndShapeInfo* tinfo = nullptr;
  CHECK(g_api->CastTypeInfoToTensorInfo(ti, &tinfo));
  size_t dims = 0;
  CHECK(g_api->GetDimensionsCount(tinfo, &dims));
  std::vector<int64_t> shape(dims);
  CHECK(g_api->GetDimensions(tinfo, shape.data(), dims));
  // Dynamic dimensions arrive as -1; use a concrete (small) value so we can
  // build a valid input tensor. All sessions run the same input, so the
  // comparison is still meaningful.
  for (auto& d : shape) {
    if (d < 1) d = 1;
  }
  g_api->ReleaseTypeInfo(ti);
  g_api->AllocatorFree(alloc, name);
  return shape;
}

static void RunSession(OrtSession* sess, const char* in_name, OrtValue* input,
                       std::vector<float>& out) {
  OrtAllocator* alloc = nullptr;
  CHECK(g_api->GetAllocatorWithDefaultOptions(&alloc));
  char* out_name = nullptr;
  CHECK(g_api->SessionGetOutputName(sess, 0, alloc, &out_name));

  OrtValue* out_val = nullptr;
  CHECK(g_api->Run(sess, nullptr, &in_name, &input, 1, &out_name, 1, &out_val));
  ReadFloatOutput(out_val, out);
  g_api->ReleaseValue(out_val);
  g_api->AllocatorFree(alloc, out_name);
}

int main(int argc, char** argv) {
  const char* model_path =
      (argc > 1) ? argv[1]
                  : "/home/shenyushi/cc-workspace/ragflow/rag/res/deepdoc/rec.ort";
  const int N = (argc > 2) ? atoi(argv[2]) : 8;

  g_api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
  if (!g_api) {
    fprintf(stderr, "failed to get OrtApi\n");
    return 1;
  }

  OrtEnv* env = nullptr;
  CHECK(g_api->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "verify", &env));

  OrtSessionOptions* ref_so = nullptr;
  CHECK(g_api->CreateSessionOptions(&ref_so));
  CHECK(g_api->SetIntraOpNumThreads(ref_so, 1));

  OrtSession* ref_sess = nullptr;
  CHECK(g_api->CreateSession(env, model_path, ref_so, &ref_sess));

  // 1) Enumerate + extract initializers.
  size_t init_count = 0;
  CHECK(g_api->SessionGetInitializerCount(ref_sess, &init_count));
  printf("[*] model has %zu constant initializers\n", init_count);

  OrtAllocator* alloc = nullptr;
  CHECK(g_api->GetAllocatorWithDefaultOptions(&alloc));

  std::vector<std::string> init_names;
  std::vector<OrtValue*> owned_initializers;  // kept alive for the whole run
  std::vector<void*> owned_buffers;           // user-owned weight buffers (free() at end)
  for (size_t i = 0; i < init_count; ++i) {
    char* nm = nullptr;
    CHECK(g_api->SessionGetInitializerName(ref_sess, i, alloc, &nm));
    OrtValue* val = nullptr;
    CHECK(g_api->SessionGetInitializer(ref_sess, nm, &val));
    init_names.emplace_back(nm);
    owned_initializers.push_back(val);
    // The initializer buffer is user-owned (malloc); record it so we free() it
    // once every session that references it has been released.
    void* buf = nullptr;
    CHECK(g_api->GetTensorMutableData(val, &buf));
    owned_buffers.push_back(buf);
    g_api->AllocatorFree(alloc, nm);
  }
  printf("[*] extracted %zu initializers into shared copies\n", owned_initializers.size());

  // 2) Build ONE shared SessionOptions injecting all initializers.
  OrtSessionOptions* shared_so = nullptr;
  CHECK(g_api->CreateSessionOptions(&shared_so));
  CHECK(g_api->SetIntraOpNumThreads(shared_so, 1));
  for (size_t i = 0; i < init_names.size(); ++i) {
    CHECK(g_api->AddInitializer(shared_so, init_names[i].c_str(), owned_initializers[i]));
  }

  long rss_before = read_rss_kib();

  // 3) Create N sessions sharing the injected weights. Measure the marginal cost
  //    of the 2nd..Nth session: if weights were deserialized per session this
  //    would be ~weight-size each; with sharing it stays flat (only the session
  //    graph/execution-plan is added, not the weights).
  std::vector<OrtSession*> shared_sessions;
  OrtSession* s0 = nullptr;
  CHECK(g_api->CreateSession(env, model_path, shared_so, &s0));
  shared_sessions.push_back(s0);
  long rss_after_first = read_rss_kib();
  for (int i = 1; i < N; ++i) {
    OrtSession* s = nullptr;
    CHECK(g_api->CreateSession(env, model_path, shared_so, &s));
    shared_sessions.push_back(s);
  }
  long rss_after = read_rss_kib();
  printf("[*] shared weights: %zu tensors copied once into %zu user buffers\n",
         owned_initializers.size(), owned_buffers.size());
  printf("[*] +1 shared session : RSS %ld -> %ld KiB (delta %ld KiB)\n",
         rss_before, rss_after_first, rss_after_first - rss_before);
  printf("[*] +%d more sessions : RSS %ld -> %ld KiB (marginal %ld KiB, %.1f KiB/session)\n",
         N - 1, rss_after_first, rss_after, rss_after - rss_after_first,
         double(rss_after - rss_after_first) / (N - 1));

  // 4) Run reference + all shared sessions with the same input; compare.
  std::vector<int64_t> shape = GetInputShape(ref_sess);
  size_t elem = 1;
  for (int64_t d : shape) elem *= static_cast<size_t>(d);
  std::vector<float> input_data(elem, 0.5f);
  OrtValue* input = MakeFloatTensor(alloc, shape, input_data);

  char* in_name = nullptr;
  CHECK(g_api->SessionGetInputName(ref_sess, 0, alloc, &in_name));

  std::vector<float> ref_out;
  RunSession(ref_sess, in_name, input, ref_out);
  printf("[*] reference output: %zu floats\n", ref_out.size());

  bool all_ok = true;
  for (int i = 0; i < N; ++i) {
    std::vector<float> out;
    RunSession(shared_sessions[i], in_name, input, out);
    if (out.size() != ref_out.size()) {
      printf("[!] session %d output size mismatch (%zu vs %zu)\n", i, out.size(),
             ref_out.size());
      all_ok = false;
      continue;
    }
    double max_diff = 0.0;
    for (size_t k = 0; k < out.size(); ++k) {
      double d = std::fabs(static_cast<double>(out[k]) - static_cast<double>(ref_out[k]));
      if (d > max_diff) max_diff = d;
    }
    printf("    shared session %d: max abs diff vs reference = %.9g %s\n", i, max_diff,
           max_diff == 0.0 ? "OK" : "MISMATCH");
    if (max_diff != 0.0) all_ok = false;
  }
  g_api->AllocatorFree(alloc, in_name);
  g_api->ReleaseValue(input);

  // 5) Cleanup.
  for (auto* s : shared_sessions) g_api->ReleaseSession(s);
  for (auto* v : owned_initializers) g_api->ReleaseValue(v);
  for (void* b : owned_buffers) free(b);
  g_api->ReleaseSessionOptions(shared_so);
  g_api->ReleaseSession(ref_sess);
  g_api->ReleaseSessionOptions(ref_so);
  g_api->ReleaseEnv(env);

  printf("\n%s: shared-weight inference %s (weights extracted once, injected into %d sessions)\n",
         all_ok ? "PASS" : "FAIL", all_ok ? "verified" : "FAILED", N);
  return all_ok ? 0 : 1;
}
