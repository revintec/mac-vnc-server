#include <zlib.h>
#define Stream z_stream
#define Init deflateInit
#define Copy deflateCopy
#define End deflateEnd
#define Deflate deflate
#define Params deflateParams
#define Version zlibVersion
#define Backend vnc_zlib_system
#include "backend.inc"
