#!/usr/bin/env python3
"""Send one QMP command to the running QEMU QMP socket."""
import json
import socket
import sys


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("usage: qmp.py <socket> <execute> [args-json] [timeout]\n")
        sys.exit(1)
    sock_path, execute = sys.argv[1], sys.argv[2]
    args = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
    timeout = float(sys.argv[4]) if len(sys.argv) > 4 else 5.0

    def recv_msg(s):
        data = b""
        while b"\n" not in data:
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
        return json.loads(data.decode()) if data else None

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(sock_path)
    recv_msg(s)  # QMP greeting
    s.sendall(b'{"execute": "qmp_capabilities"}\n')
    recv_msg(s)
    msg = {"execute": execute}
    if args:
        msg["arguments"] = args
    s.sendall((json.dumps(msg) + "\n").encode())
    reply = recv_msg(s)
    s.close()
    if reply is None or "error" in reply:
        sys.stderr.write(json.dumps(reply, indent=2) + "\n")
        sys.exit(1)
    if "return" in reply:
        print(json.dumps(reply["return"]))


if __name__ == "__main__":
    main()