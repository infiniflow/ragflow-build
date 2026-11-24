#ifndef VISIO_SHIM_UNICODE_UTF8_H
#define VISIO_SHIM_UNICODE_UTF8_H

#include <stdint.h>

#define U8_MAX_LENGTH 4

#define U8_APPEND_UNSAFE(s, i, c)                                      \
    do {                                                               \
        uint32_t _uc = (uint32_t)(c);                                  \
        if (_uc <= 0x7fu) {                                            \
            (s)[(i)++] = (unsigned char)_uc;                           \
        } else if (_uc <= 0x7ffu) {                                    \
            (s)[(i)++] = (unsigned char)(0xc0u | (_uc >> 6));          \
            (s)[(i)++] = (unsigned char)(0x80u | (_uc & 0x3fu));       \
        } else if (_uc <= 0xffffu) {                                   \
            (s)[(i)++] = (unsigned char)(0xe0u | (_uc >> 12));         \
            (s)[(i)++] = (unsigned char)(0x80u | ((_uc >> 6) & 0x3fu));\
            (s)[(i)++] = (unsigned char)(0x80u | (_uc & 0x3fu));       \
        } else if (_uc <= 0x10ffffu) {                                 \
            (s)[(i)++] = (unsigned char)(0xf0u | (_uc >> 18));         \
            (s)[(i)++] = (unsigned char)(0x80u | ((_uc >> 12) & 0x3fu));\
            (s)[(i)++] = (unsigned char)(0x80u | ((_uc >> 6) & 0x3fu));\
            (s)[(i)++] = (unsigned char)(0x80u | (_uc & 0x3fu));       \
        }                                                              \
    } while (0)

#endif
