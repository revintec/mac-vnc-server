/* Shared adapter, compiled separately against the two incompatible headers. */
#include "backend.h"

static void *create(int level, int *status) {
    Stream *stream = calloc(1, sizeof(Stream));
    if (!stream) { *status = Z_MEM_ERROR; return NULL; }
    *status = Init(stream, level);
    if (*status != Z_OK) { free(stream); return NULL; }
    return stream;
}

static void *copy(const void *source, int *status) {
    Stream *stream = calloc(1, sizeof(Stream));
    if (!stream) { *status = Z_MEM_ERROR; return NULL; }
    *status = Copy(stream, (Stream *)source);
    if (*status != Z_OK) { free(stream); return NULL; }
    return stream;
}

static void clear_buffers(Stream *stream) {
    stream->next_in = NULL;
    stream->avail_in = 0;
    stream->next_out = NULL;
    stream->avail_out = 0;
}

static void destroy(void *context) {
    End((Stream *)context);
    free(context);
}

static int process(void *context, const uint8_t *input, uint32_t *input_count,
                   uint8_t *output, uint32_t *output_count) {
    Stream *stream = context;
    stream->next_in = (uint8_t *)input;
    stream->avail_in = *input_count;
    stream->next_out = output;
    stream->avail_out = *output_count;
    int status = Deflate(stream, Z_SYNC_FLUSH);
    *input_count -= stream->avail_in;
    *output_count -= stream->avail_out;
    clear_buffers(stream);
    return status;
}

static int params(void *context, int level, uint8_t *output, uint32_t *output_count) {
    Stream *stream = context;
    stream->next_out = output;
    stream->avail_out = *output_count;
    int status = Params(stream, level, Z_DEFAULT_STRATEGY);
    *output_count -= stream->avail_out;
    clear_buffers(stream);
    return status;
}

const VNCZlibBackend Backend = { create, copy, destroy, process, params, Version };
