import Foundation

struct ScrollCopy: Equatable {
    let rect: Rect
    let sourceY: Int
    var bytes: [UInt8] {
        UInt16(rect.x).beBytes + UInt16(rect.y).beBytes + UInt16(rect.width).beBytes
            + UInt16(rect.height).beBytes + UInt32(1).beBytes
            + UInt16(rect.x).beBytes + UInt16(sourceY).beBytes
    }
}

extension Rect {
    var area: Int { max(0, width) * max(0, height) }
    func contains(_ other: Rect) -> Bool {
        other.x >= x && other.y >= y && other.x + other.width <= x + width
            && other.y + other.height <= y + height
    }
}

/// Conservative vertical-scroll reuse. Samples propose an offset; EVERY copied
/// pixel is subsequently compared with the client's last delivered framebuffer.
/// Fractional scrolling, overlays and uncertain regions fall back to pixels.
enum ScrollCopyPlanner {
    static func plan(current: Framebuffer, previous: Framebuffer, dirty: [Rect],
                     valid: Rect) -> (copies: [ScrollCopy], repaint: [Rect]) {
        guard current.width == previous.width, current.height == previous.height,
              dirty.reduce(0, { $0 + $1.area }) >= 16_384 else { return ([], dirty) }
        return current.bgra.withUnsafeBytes { now in
            previous.bgra.withUnsafeBytes { old in
                let n = now.baseAddress!, p = old.baseAddress!
                var votes: [Int: Int] = [:]
                for rect in dirty.sorted(by: { $0.area > $1.area }).prefix(4) where rect.width >= 32 && rect.height >= 64 {
                    for row in 1...5 {
                        let y = rect.y + (rect.height - 1) * row / 6
                        for column in 1...3 {
                            let x = rect.x + (rect.width - 16) * column / 4
                            let sample = n.advanced(by: y * current.bytesPerRow + x * 4)
                            // A uniform sample provides no evidence of motion.
                            if (1..<16).allSatisfy({ memcmp(sample, sample.advanced(by: $0 * 4), 4) == 0 }) { continue }
                            let lower = max(-256, valid.y - y)
                            let upper = min(256, valid.y + valid.height - 1 - y)
                            guard lower <= upper else { continue }
                            for delta in lower...upper where delta != 0 {
                                let source = p.advanced(by: (y + delta) * previous.bytesPerRow + x * 4)
                                if memcmp(sample, source, 16 * 4) == 0 { votes[delta, default: 0] += 1 }
                            }
                        }
                    }
                }
                guard let delta = votes.keys.max(by: {
                    votes[$0]! == votes[$1]! ? abs($0) > abs($1) : votes[$0]! < votes[$1]!
                }) else { return ([], dirty) }

                var copied: [Rect] = [], repaint: [Rect] = []
                for rect in dirty {
                    for y in stride(from: rect.y, to: rect.y + rect.height, by: 32) {
                        for x in stride(from: rect.x, to: rect.x + rect.width, by: 32) {
                            let tile = Rect(x: x, y: y, width: min(32, rect.x + rect.width - x),
                                height: min(32, rect.y + rect.height - y))
                            let source = Rect(x: x, y: y + delta, width: tile.width, height: tile.height)
                            var equal = valid.contains(source)
                            if equal {
                                for row in 0..<tile.height {
                                    if memcmp(n.advanced(by: (y + row) * current.bytesPerRow + x * 4),
                                              p.advanced(by: (source.y + row) * previous.bytesPerRow + x * 4),
                                              tile.width * 4) != 0 { equal = false; break }
                                }
                            }
                            if equal { copied.append(tile) } else { repaint.append(tile) }
                        }
                    }
                }
                guard copied.reduce(0, { $0 + $1.area }) >= 4096 else { return ([], dirty) }
                // All copies precede pixel updates. Directional ordering avoids
                // overwriting a source needed by a later overlapping copy.
                let ordered = merge(copied).sorted { delta > 0 ? $0.y < $1.y : $0.y > $1.y }
                return (ordered.map { ScrollCopy(rect: $0, sourceY: $0.y + delta) }, merge(repaint))
            }
        }
    }

    private static func merge(_ tiles: [Rect]) -> [Rect] {
        var rows: [Rect] = []
        for tile in tiles.sorted(by: { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }) {
            if let last = rows.last, last.y == tile.y, last.height == tile.height,
               last.x + last.width == tile.x { rows[rows.count - 1].width += tile.width }
            else { rows.append(tile) }
        }
        struct Key: Hashable { let x: Int; let width: Int }
        var result: [Rect] = [], active: [Key: Int] = [:]
        for row in rows {
            let key = Key(x: row.x, width: row.width)
            if let index = active[key], result[index].y + result[index].height == row.y {
                result[index].height += row.height
            } else { active[key] = result.count; result.append(row) }
        }
        return result
    }
}
