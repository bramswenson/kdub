#!/usr/bin/env python3
"""
Minimal client for the Tails autotest remote shell protocol.

Speaks newline-delimited JSON over a Unix socket connected to a QEMU
virtio serial channel. The daemon inside Tails accepts commands like
sh_call, file_read, file_write.

Protocol:
  Request:  [tx_id, "sh_call", user, env_dict, cmd_string]\n
  Response: [tx_id, "success", returncode, stdout, stderr]\n
  Error:    [tx_id, "error", message]\n

Usage:
  tails-remote-shell.py <socket_path> wait          # poll until shell is up
  tails-remote-shell.py <socket_path> exec <cmd>    # run cmd as root
  tails-remote-shell.py <socket_path> exec-user <user> <cmd>
  tails-remote-shell.py <socket_path> write-file <remote_path> <local_path>
"""

import base64
import json
import os
import socket
import sys
import time


class RemoteShellError(Exception):
    pass


class TailsRemoteShell:
    def __init__(self, socket_path: str, timeout: float = 10.0):
        self.socket_path = socket_path
        self.timeout = timeout
        self._tx_id = 0
        self._sock = None

    def _connect(self):
        if self._sock is not None:
            return
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._sock.settimeout(self.timeout)
        self._sock.connect(self.socket_path)

    def _disconnect(self):
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None

    def _send(self, msg: list):
        self._connect()
        data = json.dumps(msg) + "\n"
        self._sock.sendall(data.encode("utf-8"))

    def _recv(self) -> list:
        buf = b""
        while True:
            chunk = self._sock.recv(65536)
            if not chunk:
                raise RemoteShellError("Connection closed by remote")
            buf += chunk
            if b"\n" in buf:
                line = buf[: buf.index(b"\n")]
                return json.loads(line.decode("utf-8"))

    def sh_call(self, cmd: str, user: str = "root", env: dict = None) -> tuple:
        """Execute a command and return (returncode, stdout, stderr)."""
        self._tx_id += 1
        tx_id = self._tx_id
        self._send([tx_id, "sh_call", user, env or {}, cmd])
        resp = self._recv()
        if resp[0] != tx_id:
            raise RemoteShellError(f"tx_id mismatch: sent {tx_id}, got {resp[0]}")
        if resp[1] == "error":
            raise RemoteShellError(f"Remote error: {resp[2]}")
        # [tx_id, "success", returncode, stdout, stderr]
        return resp[2], resp[3], resp[4]

    def is_up(self) -> bool:
        """Check if the remote shell is responding."""
        try:
            self._disconnect()
            rc, stdout, _ = self.sh_call("echo hello")
            return rc == 0 and stdout.strip() == "hello"
        except (OSError, RemoteShellError, json.JSONDecodeError, IndexError):
            self._disconnect()
            return False

    def file_write(self, remote_path: str, data: bytes) -> int:
        """Write data to a file inside the VM. Returns bytes written."""
        self._tx_id += 1
        tx_id = self._tx_id
        b64_data = base64.b64encode(data).decode("ascii")
        self._send([tx_id, "file_write", remote_path, b64_data])
        resp = self._recv()
        if resp[0] != tx_id:
            raise RemoteShellError(f"tx_id mismatch: sent {tx_id}, got {resp[0]}")
        if resp[1] == "error":
            raise RemoteShellError(f"Remote error: {resp[2]}")
        return resp[2]

    def wait_until_up(self, timeout: int = 300, interval: int = 5):
        """Poll until the remote shell responds, or raise after timeout."""
        deadline = time.time() + timeout
        attempt = 0
        while time.time() < deadline:
            attempt += 1
            elapsed = int(time.time() + timeout - deadline)
            print(
                f"  Waiting for remote shell... "
                f"(attempt {attempt}, {elapsed}s/{timeout}s)",
                flush=True,
            )
            if self.is_up():
                print("  Remote shell is up!", flush=True)
                return
            time.sleep(interval)
        raise RemoteShellError(
            f"Remote shell not available after {timeout}s"
        )


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <socket_path> <command> [args...]")
        sys.exit(1)

    socket_path = sys.argv[1]
    command = sys.argv[2]
    shell = TailsRemoteShell(socket_path, timeout=30.0)

    if command == "wait":
        timeout = int(sys.argv[3]) if len(sys.argv) > 3 else 300
        shell.wait_until_up(timeout=timeout)

    elif command == "exec":
        if len(sys.argv) < 4:
            print("Usage: exec <cmd>")
            sys.exit(1)
        cmd = " ".join(sys.argv[3:])
        rc, stdout, stderr = shell.sh_call(cmd, user="root")
        if stdout:
            sys.stdout.write(stdout)
        if stderr:
            sys.stderr.write(stderr)
        sys.exit(rc)

    elif command == "exec-user":
        if len(sys.argv) < 5:
            print("Usage: exec-user <user> <cmd>")
            sys.exit(1)
        user = sys.argv[3]
        cmd = " ".join(sys.argv[4:])
        rc, stdout, stderr = shell.sh_call(cmd, user=user)
        if stdout:
            sys.stdout.write(stdout)
        if stderr:
            sys.stderr.write(stderr)
        sys.exit(rc)

    elif command == "write-file":
        if len(sys.argv) < 5:
            print("Usage: write-file <remote_path> <local_path>")
            sys.exit(1)
        remote_path = sys.argv[3]
        local_path = sys.argv[4]
        with open(local_path, "rb") as f:
            data = f.read()
        written = shell.file_write(remote_path, data)
        print(f"Wrote {written} bytes to {remote_path}")

    else:
        print(f"Unknown command: {command}")
        sys.exit(1)


if __name__ == "__main__":
    main()
