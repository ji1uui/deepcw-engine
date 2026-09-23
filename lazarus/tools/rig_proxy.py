#!/usr/bin/env python3
# 無線機の「電源が切れている」「応答しない」「遠隔で電源を入れると数秒後に
# 起きる」を、`rigctld` の前に立てて真似る試験用の中継です（`cli/rig_check`、
# 要件 FR-T.5・FR-T.6、付録 BT）。**試験にだけ使います。**
#
# 状態は `--control` のファイルに 1 語で書きます（中継は 0.1 秒ごとに読む）:
#   pass    そのまま中継する（電源が入っている無線機）
#   silent  受け取った命令を捨て、何も返さない（応答しない無線機・電源断）
#   off     silent と同じだが、`set_powerstat 1` だけは受けて `RPRT 0` を返し、
#           `--boot` 秒後に pass になる（遠隔で電源を入れられる無線機）
#
# 受け取った命令の行は `--log` に書きます（試験が「何が届いたか」を見るため）。
#
# A test-only relay placed in front of `rigctld` that imitates a rig that is
# switched off, one that does not answer, and one that wakes a few seconds
# after a remote power-on (`cli/rig_check`, requirements FR-T.5, FR-T.6,
# appendix BT). The state is one word in the `--control` file (read every
# 0.1 s): pass relays everything; silent swallows commands and answers nothing;
# off is silent except that `set_powerstat 1` is answered with `RPRT 0` and the
# relay turns to pass after `--boot` seconds. Every command line received is
# written to `--log`.

import argparse
import os
import select
import socket
import time


def read_mode(path):
    try:
        with open(path) as f:
            return f.read().strip() or "pass"
    except OSError:
        return "pass"


def write_mode(path, mode):
    with open(path, "w") as f:
        f.write(mode)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--listen", type=int, required=True)
    p.add_argument("--upstream", type=int, required=True)
    p.add_argument("--control", required=True)
    p.add_argument("--log", required=True)
    p.add_argument("--boot", type=float, default=2.0)
    a = p.parse_args()

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", a.listen))
    server.listen(4)
    pairs = {}      # client socket -> upstream socket
    back = {}       # upstream socket -> client socket
    pending = {}    # client socket -> partial line
    boot_at = None

    def log(line):
        with open(a.log, "a") as f:
            f.write(line + "\n")

    def drop(c):
        u = pairs.pop(c, None)
        pending.pop(c, None)
        if u is not None:
            back.pop(u, None)
            u.close()
        c.close()

    while True:
        mode = read_mode(a.control)
        if boot_at is not None and time.monotonic() >= boot_at:
            boot_at = None
            write_mode(a.control, "pass")
            mode = "pass"
        socks = [server] + list(pairs) + list(back)
        ready, _, _ = select.select(socks, [], [], 0.1)
        for s in ready:
            if s is server:
                c, _ = server.accept()
                u = socket.create_connection(("127.0.0.1", a.upstream))
                pairs[c] = u
                back[u] = c
                pending[c] = b""
                continue
            if s in back:
                data = s.recv(65536)
                c = back[s]
                if not data:
                    drop(c)
                    continue
                if read_mode(a.control) == "pass":
                    c.sendall(data)
                continue
            data = s.recv(65536)
            if not data:
                drop(s)
                continue
            pending[s] += data
            while b"\n" in pending[s]:
                line, pending[s] = pending[s].split(b"\n", 1)
                text = line.decode("latin-1")
                # 行ごとに読み直します（試験が状態を変えた直後の行を取り違えない）。
                # Re-read per line, so a line right after the test changes the
                # state is not handled in the old one.
                mode = read_mode(a.control)
                log(f"{time.time():.3f} {mode} {text}")
                if mode == "pass":
                    pairs[s].sendall(line + b"\n")
                elif mode == "off" and "set_powerstat" in text and text.rstrip().endswith("1"):
                    s.sendall(b"RPRT 0\n")
                    boot_at = time.monotonic() + a.boot
                    write_mode(a.control, "booting")
                # silent / off / booting: swallowed, nothing answered


if __name__ == "__main__":
    main()
