#include "backend.h"

struct VNCZlibStream {
    const VNCZlibBackend *backend;
    void *context;
};

VNCZlibStream *vnc_zlib_create(int use_ng, int level, int *status) {
    VNCZlibStream *stream = calloc(1, sizeof(*stream));
    if (!stream) { *status = -4; return NULL; } // Z_MEM_ERROR
    stream->backend = use_ng ? &vnc_zlib_ng : &vnc_zlib_system;
    stream->context = stream->backend->create(level, status);
    if (!stream->context) { free(stream); return NULL; }
    return stream;
}

VNCZlibStream *vnc_zlib_copy(const VNCZlibStream *source, int *status) {
    VNCZlibStream *stream = calloc(1, sizeof(*stream));
    if (!stream) { *status = -4; return NULL; }
    stream->backend = source->backend;
    stream->context = stream->backend->copy(source->context, status);
    if (!stream->context) { free(stream); return NULL; }
    return stream;
}

void vnc_zlib_destroy(VNCZlibStream *stream) {
    if (!stream) return;
    stream->backend->destroy(stream->context);
    free(stream);
}

int vnc_zlib_process(VNCZlibStream *stream, const uint8_t *input,
                     uint32_t *input_count, uint8_t *output, uint32_t *output_count) {
    return stream->backend->process(stream->context, input, input_count, output, output_count);
}

int vnc_zlib_params(VNCZlibStream *stream, int level, uint8_t *output, uint32_t *output_count) {
    return stream->backend->params(stream->context, level, output, output_count);
}

const char *vnc_zlib_version(int use_ng) {
    return (use_ng ? &vnc_zlib_ng : &vnc_zlib_system)->version();
}
