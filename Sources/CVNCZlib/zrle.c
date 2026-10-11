// RFC 6143 ZRLE tile construction. Original implementation under the project's
// MIT license. Fixed scratch storage, one palette/run census, one output pass.
#include "include/CVNCZlib.h"
#include <stddef.h>
#include <string.h>

static uint8_t *pixel_out(uint8_t *out, uint32_t p, int bytes, int big) {
    for (int i = 0; i < bytes; ++i)
        *out++ = (uint8_t)(p >> (8 * (big ? bytes - 1 - i : i)));
    return out;
}
static uint8_t *run_out(uint8_t *out, unsigned length) {
    unsigned n = length - 1;
    while (n >= 255) { *out++ = 255; n -= 255; }
    *out++ = (uint8_t)n;
    return out;
}

size_t vnc_zrle_tiles(const uint8_t *bgra, size_t stride, int width, int height,
                     VNCZRLEFormat f, uint8_t *out, size_t capacity) {
    if (!bgra || !out || width <= 0 || height <= 0 ||
        f.bytes < 1 || f.bytes > 4 || f.shift_r > 31 ||
        f.shift_g > 31 || f.shift_b > 31) return 0;
    const size_t bound = (size_t)width * height * f.bytes +
                        (size_t)((width + 63) / 64) * ((height + 63) / 64);
    if (capacity < bound) return 0;
    uint8_t *start = out;
    uint32_t pixels[4096], palette[127], keys[512];
    uint16_t runs[4096];
    uint8_t indices[4096], values[512];
    const int fast = f.max_r == 255 && f.max_g == 255 && f.max_b == 255 &&
                     f.shift_r == 16 && f.shift_g == 8 && f.shift_b == 0;
    for (int y0 = 0; y0 < height; y0 += 64) {
        const int h = height - y0 < 64 ? height - y0 : 64;
        for (int x0 = 0; x0 < width; x0 += 64) {
            const int w = width - x0 < 64 ? width - x0 : 64;
            const unsigned n = (unsigned)(w * h);
            unsigned count = 0, nruns = 0, pos = 0;
            size_t plain = 1, prle = 1;
            memset(values, 255, sizeof(values));
            for (int y = 0; y < h; ++y) {
                const uint8_t *src = bgra + (size_t)(y0 + y) * stride + x0 * 4;
                for (int x = 0; x < w; ++x, src += 4, ++pos) {
                    uint32_t p;
                    if (fast) p = src[0] | ((uint32_t)src[1] << 8) | ((uint32_t)src[2] << 16);
                    else p = (((uint32_t)src[2] * f.max_r / 255) << f.shift_r) |
                             (((uint32_t)src[1] * f.max_g / 255) << f.shift_g) |
                             (((uint32_t)src[0] * f.max_b / 255) << f.shift_b);
                    p >>= f.omit_low_byte ? 8 : 0;
                    pixels[pos] = p;
                    if (count <= 127) {
                        unsigned slot = (p * 2654435761u) >> 23;
                        while (values[slot] != 255 && keys[slot] != p) slot = (slot + 1) & 511;
                        if (values[slot] == 255) {
                            if (count == 127) { count = 128; indices[pos] = 0; }
                            else {
                                keys[slot] = p; values[slot] = (uint8_t)count;
                                palette[count++] = p; indices[pos] = values[slot];
                            }
                        } else indices[pos] = values[slot];
                    }
                }
            }
            // Runs can span rows inside one tile, but never cross a tile.
            for (unsigned i = 0; i < n;) {
                unsigned end = i + 1;
                while (end < n && pixels[end] == pixels[i]) ++end;
                unsigned length = end - i;
                runs[nruns++] = (uint16_t)length;
                plain += f.bytes + 1 + (length - 1) / 255;
                prle += 1 + (length > 1 ? 1 + (length - 1) / 255 : 0);
                i = end;
            }
            size_t best = 1 + n * f.bytes;
            int mode = 0, bits = count <= 2 ? 1 : count <= 4 ? 2 : 4;
            if (count == 1 && 1u + f.bytes < best) { mode = 1; best = 1 + f.bytes; }
            else if (count <= 16) {
                size_t packed = 1 + count * f.bytes + (size_t)((w * bits + 7) / 8) * h;
                if (packed < best) { best = packed; mode = (int)count; }
            }
            if (plain < best) { best = plain; mode = 128; }
            prle += count * f.bytes;
            if (count >= 2 && count <= 127 && prle < best) mode = 128 + (int)count;
            *out++ = (uint8_t)mode;
            if (mode == 0) {
                for (unsigned i = 0; i < n; ++i) out = pixel_out(out, pixels[i], f.bytes, f.big_endian);
            } else if (mode == 1) {
                out = pixel_out(out, palette[0], f.bytes, f.big_endian);
            } else if (mode < 128) {
                for (unsigned i = 0; i < count; ++i) out = pixel_out(out, palette[i], f.bytes, f.big_endian);
                pos = 0;
                for (int y = 0; y < h; ++y) {
                    unsigned packed = 0, used = 0;
                    for (int x = 0; x < w; ++x) {
                        packed = (packed << bits) | indices[pos++]; used += bits;
                        if (used == 8) { *out++ = (uint8_t)packed; packed = used = 0; }
                    }
                    if (used) *out++ = (uint8_t)(packed << (8 - used));
                }
            } else {
                if (mode > 128)
                    for (unsigned i = 0; i < count; ++i) out = pixel_out(out, palette[i], f.bytes, f.big_endian);
                pos = 0;
                for (unsigned r = 0; r < nruns; ++r) {
                    unsigned length = runs[r];
                    if (mode == 128) {
                        out = pixel_out(out, pixels[pos], f.bytes, f.big_endian);
                        out = run_out(out, length);
                    } else if (length == 1) *out++ = indices[pos];
                    else { *out++ = indices[pos] | 128; out = run_out(out, length); }
                    pos += length;
                }
            }
        }
    }
    return (size_t)(out - start);
}
