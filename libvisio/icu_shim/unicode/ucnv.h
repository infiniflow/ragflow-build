#ifndef VISIO_SHIM_UNICODE_UCNV_H
#define VISIO_SHIM_UNICODE_UCNV_H

#include <unicode/utypes.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VisioUConverter UConverter;

UConverter *visio_ucnv_open(const char *converter_name, UErrorCode *err);
UChar32 visio_ucnv_getNextUChar(
    UConverter *converter,
    const char **source,
    const char *source_limit,
    UErrorCode *err);
void visio_ucnv_close(UConverter *converter);

#define ucnv_open visio_ucnv_open
#define ucnv_getNextUChar visio_ucnv_getNextUChar
#define ucnv_close visio_ucnv_close

#ifdef __cplusplus
}
#endif

#endif
