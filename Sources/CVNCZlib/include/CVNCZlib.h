#ifndef CVNC_ZLIB_H
#define CVNC_ZLIB_H
#include <stdint.h>

// No zlib headers cross this boundary: system zlib and zlib-ng keep distinct
// types and symbols. The stream lives at a stable C heap address until freed.
typedef struct VNCZlibStream VNCZlibStream;
VNCZlibStream *vnc_zlib_create(int use_ng, int level, int *status);
VNCZlibStream *vnc_zlib_copy(const VNCZlibStream *source, int *status);
void vnc_zlib_destroy(VNCZlibStream *stream);
// Counts are available lengths on entry, consumed/produced lengths on return.
// Every call uses Z_SYNC_FLUSH and clears borrowed buffer pointers on return.
int vnc_zlib_process(VNCZlibStream *stream, const uint8_t *input,
                     uint32_t *input_count, uint8_t *output, uint32_t *output_count);
int vnc_zlib_params(VNCZlibStream *stream, int level,
                    uint8_t *output, uint32_t *output_count);
const char *vnc_zlib_version(int use_ng);
#endif
