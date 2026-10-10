#include "vendor/zlib-ng.h"
#define Stream zng_stream
#define Init zng_deflateInit
#define Copy zng_deflateCopy
#define End zng_deflateEnd
#define Deflate zng_deflate
#define Params zng_deflateParams
#define Version zlibng_version
#define Backend vnc_zlib_ng
#include "backend.inc"
