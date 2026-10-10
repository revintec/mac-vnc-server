#!/usr/bin/env python3
"""Add timing probes to a disposable copy of the server (never edits the checkout)."""
from pathlib import Path
import hashlib, json, shutil, sys
source, dest = map(Path, sys.argv[1:3])
if dest.exists(): raise SystemExit(f'Destination already exists: {dest}')
shutil.copytree(source, dest, ignore=shutil.ignore_patterns('.build', '.git'))
files = dest / 'Sources/mac-vnc-server'
inputs = [source / 'Package.swift'] + [p for p in (source / 'Sources').rglob('*')
    if p.suffix in {'.swift', '.c', '.h', '.inc'}]
manifest = {str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(inputs)}
(dest / 'source-sha256.json').write_text(json.dumps(manifest, indent=2)+'\n')
(files / 'PipelineProfile.swift').write_text('''import Foundation
import Darwin

enum PipelineProfile {
    static let sink = Sink()
    final class Sink: @unchecked Sendable {
        let lock = NSLock()
        let file: UnsafeMutablePointer<FILE>?
        init() {
            file = ProcessInfo.processInfo.environment["MAC_VNC_PROFILE"].flatMap { fopen($0, "w") }
            if let file { setvbuf(file, nil, _IOFBF, 1024 * 1024) }
        }
    }
    struct Span {
        let name: String
        let wall = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        func end(_ info: String = "") {
            let endWall = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let endCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            PipelineProfile.emit(name, wall, endWall - wall, endCPU - cpu, info)
        }
    }
    static func emit(_ name: String, _ start: UInt64, _ wall: UInt64, _ cpu: UInt64, _ info: String) {
        guard let file = sink.file else { return }
        sink.lock.lock()
        defer { sink.lock.unlock() }
        fputs("\\(name),\\(start),\\(wall),\\(cpu),\\(pthread_mach_thread_np(pthread_self())),\\(info)\\n", file)
    }
    static func point(_ name: String, _ info: String = "") {
        emit(name, clock_gettime_nsec_np(CLOCK_UPTIME_RAW), 0, 0, info)
    }
}
''')
def replace(name, old, new, count=1):
    p = files / name
    s = p.read_text()
    if s.count(old) != count: raise SystemExit(f'{name}: expected {count} occurrences of {old!r}, got {s.count(old)}')
    p.write_text(s.replace(old, new))
def span(name, signature, label):
    replace(name, signature, signature + f'\n        let profile = PipelineProfile.Span(name: "{label}")\n        defer {{ profile.end() }}')
span('RFBServer.swift', 'private func handleFramebufferUpdateRequestMessage() throws {', 'request_read_parse')
replace('RFBServer.swift', '        state.signal()\n        state.unlock()\n        if requestNumber', '        PipelineProfile.point("request_queued", "fd=\\(socket.fd);request=\\(requestNumber)")\n        state.signal()\n        state.unlock()\n        if requestNumber')
replace('RFBServer.swift', '        frameHadNetworkStall = false\n        throttleFrameRate()', '        let profileFrame = PipelineProfile.Span(name: "response_including_throttle")\n        defer { profileFrame.end("fd=\\(socket.fd);unsolicited=\\(unsolicited)") }\n        frameHadNetworkStall = false\n        throttleFrameRate()')
span('RFBServer.swift', 'private func throttleFrameRate() {', 'fps_wait')
span('RFBServer.swift', 'private func captureClientFramebuffer() throws -> (framebuffer: Framebuffer, sourceLayout: VirtualDisplayLayout) {', 'snapshot_cursor_scale')
replace('RFBServer.swift', '        var captured = try capture.capture()', '        var captured = try capture.capture()\n        PipelineProfile.point("snapshot_sequence", "seq=\\(captured.sequence ?? 0)")')
replace('RFBServer.swift', '        let diffStarted = logger.isVerbose ? Date() : .distantPast', '        let profileDiff = PipelineProfile.Span(name: "dirty_region_diff")\n        let diffStarted = logger.isVerbose ? Date() : .distantPast')
replace('RFBServer.swift', '        let diffDuration = logger.isVerbose ? Date().timeIntervalSince(diffStarted) : 0', '        profileDiff.end()\n        let diffDuration = logger.isVerbose ? Date().timeIntervalSince(diffStarted) : 0')
replace('RFBServer.swift', '        try socket.writeAll(updateChunks, onStall:', '        let profileWrite = PipelineProfile.Span(name: "encrypt_and_write")\n        try socket.writeAll(updateChunks, onStall:')
replace('RFBServer.swift', '        let updateBytes = updateChunks.reduce(0)', '        profileWrite.end()\n        PipelineProfile.point("response_sent", "fd=\\(socket.fd);seq=\\(prepared.framebuffer.sequence ?? 0);pixels=\\(prepared.changedPixels);bytes=\\(updateChunks.reduce(0) { $0 + $1.count });rects=\\(rectCount)")\n        let updateBytes = updateChunks.reduce(0)')
span('RFBServer.swift', 'private func applyPointerEvent(mask: UInt8, x: UInt16, y: UInt16) {', 'input_inject_pointer')
span('RFBServer.swift', 'private func applyKeyEvent(down: Bool, keysym: UInt32) {', 'input_inject_key')
# Both backends and the transaction path use the same pack/compress boundary.
replace('ZlibEncoding.swift', '        try RawEncoding.encode(rect: rect, framebuffer: framebuffer, pixelFormat: pixelFormat, into: &rawBuffer)', '        let profilePack = PipelineProfile.Span(name: "pixel_pack")\n        try RawEncoding.encode(rect: rect, framebuffer: framebuffer, pixelFormat: pixelFormat, into: &rawBuffer)\n        profilePack.end()\n        let profileDeflate = PipelineProfile.Span(name: "zlib_deflate")\n        defer { profileDeflate.end("backend=\\(configuration.backend.rawValue);level=\\(stream.level)") }')
span('AppleEncryption.swift', '        func seal(_ payload: [UInt8]) throws -> [UInt8] {', 'aes_record_seal')
span('Socket.swift', '    private func writeRaw(_ bytes: [UInt8], idleTimeout: TimeInterval, onStall: (() -> Void)?) throws {', 'socket_write_raw')
replace('StreamingScreenCapture.swift', '        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)', '        let profileCopy = PipelineProfile.Span(name: "capture_buffer_copy")\n        defer { profileCopy.end() }\n        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)')
replace('StreamingScreenCapture.swift', '        sequence &+= 1', '        sequence &+= 1\n        PipelineProfile.point("capture_ready", "seq=\\(sequence);pts=\\(presentationTime ?? 0)")')
# Flush stage records when a client disconnects, and diagnostic stdout per line.
replace('Logging.swift', '        fputs("\\(message)\\n", stream)', '        fputs("\\(message)\\n", stream)\n        fflush(stream)\n        PipelineProfile.sink.lock.withLock { if let file = PipelineProfile.sink.file { fflush(file) } }')
print(dest)
