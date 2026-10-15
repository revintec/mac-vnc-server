#!/usr/bin/env python3
"""Exercise production executable lookup with real PATH, wrapper and exec launches.

The fixture spawns/re-executes only itself. --root also tests launchctl asuser
through the caller-authorized sudo zsh entry point. No server, capture, account
password, service registration or input injection is involved.
"""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = r'''
import Darwin
import Foundation

@main struct Fixture {
    static func main() throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let executable = try CurrentExecutable.url()
        if CommandLine.arguments[1] == "child" {
            print("CHILD \(executable.path)")
            return
        }
        let legacy = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        print("LEGACY \(legacy.path)")
        print("CURRENT \(executable.path)")
        if CommandLine.arguments[1] == "exec" {
            let path = strdup(executable.path)!, child = strdup("child")!
            defer { free(path); free(child) }
            var args: [UnsafeMutablePointer<CChar>?] = [path, child, nil]
            execv(path, &args)
            fatalError("exec failed: \(errno)")
        }
        let process = Process()
        if CommandLine.arguments[1] == "launchctl" {
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["asuser", CommandLine.arguments[2], executable.path, "child"]
        } else {
            process.executableURL = executable
            process.arguments = ["child"]
        }
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        try process.run()
        process.waitUntilExit()
        exit(process.terminationStatus)
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", action="store_true")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="mac-vnc-executable-") as directory:
        folder = Path(directory).resolve()
        source = folder / "Fixture.swift"
        original = folder / "fixture"
        source.write_text(FIXTURE)
        subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                        str(ROOT / "Sources/mac-vnc-server/CurrentExecutable.swift"),
                        str(source), "-o", str(original)], check=True)
        destination = folder / "relocated bin"
        destination.mkdir()
        binary = destination / "server probe"
        original.rename(binary)
        alias = folder / "server-alias"
        alias.symlink_to(binary)
        # A bare argv[0] must not accidentally select a same-named local file.
        (folder / binary.name).write_text("#!/bin/sh\nexit 41\n")
        (folder / binary.name).chmod(0o755)
        environment = {"PATH": str(destination) + os.pathsep + os.defpath}

        def check(name, command, *, executable=None, legacy_wrong=False):
            result = subprocess.run(command, executable=executable, cwd=folder,
                                    env=environment, capture_output=True, text=True, timeout=15)
            assert result.returncode == 0, (name, result.returncode, result.stdout, result.stderr)
            lines = result.stdout.splitlines()
            paths = {line.split(" ", 1)[0]: Path(line.split(" ", 1)[1]).resolve() for line in lines}
            assert paths.get("CURRENT") == binary, (name, lines)
            assert paths.get("CHILD") == binary, (name, lines)
            if legacy_wrong:
                assert paths.get("LEGACY") != binary, (name, lines)
            print("PASS " + name)

        for mode in ["spawn", "exec"]:
            check(mode + " absolute relocated binary", [str(binary), mode])
            check(mode + " relative path with spaces", ["./relocated bin/server probe", mode])
            check(mode + " symlink", [str(alias), mode])
            check(mode + " PATH with local decoy", [binary.name, mode], legacy_wrong=True)
            check(mode + " wrapper argv[0]", ["wrapper-command", mode],
                  executable=str(binary), legacy_wrong=True)
        if args.root:
            command = "exec -a server-command " + shlex.join([str(binary), "launchctl", str(os.getuid())])
            check("root launchctl asuser with bare argv[0]", ["/usr/bin/sudo", "-n", "/bin/zsh", "-c", command],
                  legacy_wrong=True)


if __name__ == "__main__":
    main()
