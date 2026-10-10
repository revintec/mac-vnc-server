#include "include/CVNCZlib.h"
#include <stdlib.h>

typedef struct {
    void *(*create)(int, int *);
    void *(*copy)(const void *, int *);
    void (*destroy)(void *);
    int (*process)(void *, const uint8_t *, uint32_t *, uint8_t *, uint32_t *);
    int (*params)(void *, int, uint8_t *, uint32_t *);
    const char *(*version)(void);
} VNCZlibBackend;
extern const VNCZlibBackend vnc_zlib_ng;
extern const VNCZlibBackend vnc_zlib_system;
