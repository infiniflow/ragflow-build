#ifndef SVGRENDER_H
#define SVGRENDER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int32_t svgrender_render_png(
    const uint8_t *svg_data,
    size_t svg_len,
    uint32_t max_side,
    uint64_t max_pixels,
    uint8_t **out_png,
    size_t *out_len,
    char **out_err);

void svgrender_free_bytes(uint8_t *ptr, size_t len);
void svgrender_free_string(char *ptr);

#ifdef __cplusplus
}
#endif

#endif /* SVGRENDER_H */
