#!/usr/bin/env python3
"""Send one HMP command to the running QEMU monitor socket."""
import socket
import sys


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("usage: hmp.py <socket> <command> [timeout]\n")
        sys.exit(1)
    sock_path, cmd = sys.argv[1], sys.argv[2]
    timeout = float(sys.argv[3]) if len(sys.argv) > 3 else 5.0
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(sock_path)
    s.sendall((cmd + "\n").encode())
    try:
        while True:
            data = s.recv(4096)
            if not data:
                break
            if b"(qemu)" in data:
                break
    except socket.timeout:
        pass
    s.close()


if __name__ == "__main__":
    main()
