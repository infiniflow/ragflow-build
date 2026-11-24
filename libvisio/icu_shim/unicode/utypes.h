#ifndef VISIO_SHIM_UNICODE_UTYPES_H
#define VISIO_SHIM_UNICODE_UTYPES_H

#include <stdint.h>
#include <unicode/utf8.h>

typedef int32_t UChar32;
typedef int32_t UErrorCode;

#define U_ZERO_ERROR ((UErrorCode)0)
#define U_SUCCESS(x) ((x) <= 0)
#define U_FAILURE(x) ((x) > 0)
#define U_IS_UNICODE_CHAR(c) \
    ((uint32_t)(c) <= 0x10ffffu && ((uint32_t)(c) < 0xd800u || (uint32_t)(c) > 0xdfffu))

#endif
