#!/usr/bin/env python3
"""Validate every pixel against RFC 6143, then summarize compare-codecs.swift.

Uses Python's independent persistent DEFLATE decoder. No screenshot data or UI.
"""
import collections
import json
import math
from pathlib import Path
import statistics
import struct
import sys
import zlib


def decode_zrle(data, width, height):
    offset = 0
    output = bytearray(width * height * 4)
    modes = collections.Counter()

    def take(count):
        nonlocal offset
        if offset + count > len(data):
            raise ValueError(f"tile stream exhausted at byte {offset}, requesting {count}")
        result = data[offset:offset + count]
        offset += count
        return result

    def byte():
        return take(1)[0]

    def run_length():
        count = 1
        while True:
            value = byte()
            count += value
            if value != 255:
                return count

    for ty in range(0, height, 64):
        th = min(64, height - ty)
        for tx in range(0, width, 64):
            tw = min(64, width - tx)
            count = tw * th
            mode = byte()
            modes[mode] += 1
            if mode == 0:
                tile = take(count * 4)
            elif mode == 1:
                tile = take(4) * count
            elif 2 <= mode <= 16:
                palette = [take(4) for _ in range(mode)]
                bits = 1 if mode == 2 else 2 if mode <= 4 else 4
                tile = bytearray()
                for _ in range(th):
                    row = take((tw * bits + 7) // 8)
                    for x in range(tw):
                        index = (row[x * bits // 8] >> (8 - bits - (x * bits) % 8)) & ((1 << bits) - 1)
                        if index >= len(palette):
                            raise ValueError(f"packed palette index {index} exceeds palette size {len(palette)}")
                        tile.extend(palette[index])
            elif mode == 128 or 130 <= mode <= 255:
                palette = [take(4) for _ in range(mode - 128)] if mode != 128 else None
                tile = bytearray()
                while len(tile) < count * 4:
                    if palette is None:
                        pixel = take(4)
                        length = run_length()
                    else:
                        index = byte()
                        if (index & 127) >= len(palette):
                            raise ValueError(f"RLE palette index {index & 127} exceeds palette size {len(palette)}")
                        pixel = palette[index & 127]
                        length = run_length() if index & 128 else 1
                    if len(tile) + length * 4 > count * 4:
                        raise ValueError("pixel run extends beyond tile")
                    tile.extend(pixel * length)
            else:
                raise ValueError(f"invalid ZRLE tile mode {mode}")
            for row in range(th):
                start = ((ty + row) * width + tx) * 4
                output[start:start + tw * 4] = tile[row * tw * 4:(row + 1) * tw * 4]
    if offset != len(data):
        raise ValueError(f"{len(data) - offset} extra bytes after final tile")
    return output, modes


def stats(values):
    values = sorted(values)
    return dict(n=len(values), mean=statistics.mean(values), p50=statistics.median(values),
                p95=values[math.ceil(len(values) * .95) - 1], max=max(values))


def check_reference_vectors():
    a, b = bytes([1, 2, 3, 0]), bytes([4, 5, 6, 0])
    vectors = [
        (bytes([0]) + a + b, 2, a + b),
        (bytes([1]) + a, 2, a * 2),
        (bytes([2]) + a + b + bytes([0x50]), 4, a + b + a + b),
        (bytes([128]) + a + bytes([3]), 4, a * 4),
        (bytes([130]) + a + b + bytes([0x80, 2, 1]), 4, a * 3 + b),
    ]
    for encoded, width, expected in vectors:
        assert decode_zrle(encoded, width, 1)[0] == expected


def main(root):
    check_reference_vectors()
    results = []
    fixture_cache = {}
    for case in json.loads((root / 'timings.json').read_text()):
        payloads = (root / (case['name'] + '.payloads')).read_bytes()
        position = 0
        inflater = zlib.decompressobj()
        failures = []
        valid = 0
        mismatch_pixels = 0
        modes = collections.Counter()
        for frame, sample in enumerate(case['samples']):
            fixture = root / f"{case['scenario']}-{sample['fixture']}.bgra"
            if fixture not in fixture_cache:
                fixture_cache[fixture] = fixture.read_bytes()
            expected = fixture_cache[fixture]
            frame_ok = True
            for y in range(0, case['height'], case['rect_height']):
                length, = struct.unpack_from('>I', payloads, position)
                position += 4
                compressed = payloads[position:position + length]
                position += length
                raw = inflater.decompress(compressed)
                height = min(case['rect_height'], case['height'] - y)
                try:
                    if case['codec'] == 'zrle':
                        decoded, counts = decode_zrle(raw, case['width'], height)
                        modes.update(counts)
                    else:
                        decoded = raw
                    target = expected[y * case['width'] * 4:(y + height) * case['width'] * 4]
                    if decoded != target:
                        bad = sum(decoded[i:i + 4] != target[i:i + 4] for i in range(0, len(target), 4))
                        mismatch_pixels += bad
                        raise ValueError(f"{bad} decoded pixels differ from source")
                except ValueError as error:
                    frame_ok = False
                    if len(failures) < 3:
                        failures.append(dict(frame=frame, rect_y=y, error=str(error)))
            valid += frame_ok
        assert position == len(payloads), case['name']
        timed = [s for s in case['samples'] if not s['warmup']]
        result = {k: case[k] for k in ['name', 'scenario', 'codec', 'pass', 'width', 'height', 'depth']}
        result.update(wall_ms=stats([s['wall_ms'] for s in timed]), cpu_ms=stats([s['cpu_ms'] for s in timed]),
                      payload_bytes=stats([s['payload_bytes'] for s in timed]),
                      valid_frames=valid, checked_frames=len(case['samples']),
                      mismatching_pixels=mismatch_pixels, failure_examples=failures, tile_modes=dict(modes))
        results.append(result)
        print(f"{case['name']:25} wall={result['wall_ms']['p50']:7.3f}ms cpu={result['cpu_ms']['p50']:7.3f}ms "
              f"bytes={result['payload_bytes']['mean']:9.0f} valid={valid}/{len(case['samples'])} {failures[:1]}")
    (root / 'summary.json').write_text(json.dumps(results, indent=2) + '\n')


if __name__ == '__main__':
    main(Path(sys.argv[1]))
