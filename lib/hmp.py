#!/usr/bin/env python3
"""Send one HMP command to the running QEMU monitor socket."""
import socket
import sys


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("usage: hmp.py <socket> <command> [timeout] [strict]\n")
        sys.exit(1)
    sock_path, cmd = sys.argv[1], sys.argv[2]
    timeout = float(sys.argv[3]) if len(sys.argv) > 3 else 5.0
    strict = len(sys.argv) > 4 and sys.argv[4] == "strict"
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(sock_path)
    # QEMU greets every connection with a banner ending in "(qemu) ". Drain it
    # first so the command's own response isn't confused with the greeting.
    try:
        while True:
            data = s.recv(4096)
            if not data:
                break
            if b"(qemu)" in data:
                break
    except socket.timeout:
        pass
    s.sendall((cmd + "\n").encode())
    out = b""
    try:
        while True:
            data = s.recv(4096)
            if not data:
                break
            out += data
            if b"(qemu)" in data:
                break
    except socket.timeout:
        pass
    s.close()
    if strict:
        sys.stderr.write(out.decode(errors="replace"))
        if b"Error" in out or b"not found" in out:
            sys.exit(1)


if __name__ == "__main__":
    main()
