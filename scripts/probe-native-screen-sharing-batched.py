#!/usr/bin/env python3
"""Run the native probe with its startup replies delivered in one TCP batch.

Build scripts/probe-native-screen-sharing.m as /tmp/mac-vnc-native-control-probe,
or set MAC_VNC_NATIVE_PROBE_BINARY to its path. Use this script as
MAC_VNC_NATIVE_PROBE when running the opt-in Swift interoperability tests.
Only the isolated test connection passes through this loopback proxy.
"""

import os
import socket
import subprocess
import sys
import threading
import time
import urllib.parse


def relay_client(client, server):
    try:
        while data := client.recv(65536):
            server.sendall(data)
    except OSError:
        pass
    finally:
        shutdown_write(server)


def shutdown_write(connection):
    try:
        connection.shutdown(socket.SHUT_WR)
    except OSError:
        pass


def relay_server(server, client):
    def read_exact(count):
        result = bytearray()
        while len(result) < count:
            data = server.recv(count - len(result))
            if not data:
                raise EOFError("test server closed during handshake")
            result.extend(data)
        return result

    try:
        client.sendall(read_exact(12))
        security = read_exact(2)
        client.sendall(security)
        if security == b"\x01\x1e":
            # Apple Diffie-Hellman challenge: generator, size, prime, public key.
            header = read_exact(4)
            client.sendall(header + read_exact(2 * int.from_bytes(header[2:], "big")))
        elif security == b"\x01\x02":
            client.sendall(read_exact(16))
        else:
            raise ValueError("unexpected test authentication type")
        client.sendall(read_exact(4))
        header = read_exact(24)
        client.sendall(header + read_exact(int.from_bytes(header[20:24], "big")))

        # Deliver nearby replies together to exercise asynchronous layout and
        # mode callbacks that ordinary loopback delivery can serialize.
        deadline = time.monotonic() + 0.2
        pending = bytearray()
        while time.monotonic() < deadline:
            server.settimeout(max(0.001, deadline - time.monotonic()))
            try:
                data = server.recv(65536)
            except socket.timeout:
                break
            if not data:
                break
            pending.extend(data)
        server.settimeout(None)
        if pending:
            client.sendall(pending)
        while data := server.recv(65536):
            client.sendall(data)
    except (OSError, EOFError):
        pass
    finally:
        shutdown_write(client)


def main():
    if len(sys.argv) != 4:
        return 2
    native = os.environ.get("MAC_VNC_NATIVE_PROBE_BINARY", "/tmp/mac-vnc-native-control-probe")
    url = urllib.parse.urlsplit(sys.argv[1])
    if url.scheme != "vnc" or url.hostname != "127.0.0.1" or url.port is None or url.query or url.fragment:
        raise ValueError("the batching probe accepts only plain VNC URLs to loopback test servers")
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(5)
        proxy_url = urllib.parse.urlunsplit((url.scheme,
            f"127.0.0.1:{listener.getsockname()[1]}", url.path, url.query, url.fragment))
        with subprocess.Popen([native, proxy_url, *sys.argv[2:]]) as probe:
            try:
                client, _ = listener.accept()
                with client, socket.create_connection((url.hostname, url.port), timeout=5) as server:
                    server.settimeout(None)
                    for relay, pair in ((relay_client, (client, server)), (relay_server, (server, client))):
                        threading.Thread(target=relay, args=pair, daemon=True).start()
                    return probe.wait(timeout=59)
            finally:
                if probe.poll() is None:
                    probe.kill()


if __name__ == "__main__":
    sys.exit(main())
