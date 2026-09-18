#!/usr/bin/env python3
"""tests/pty-keys.py - run the interactive board on a pseudo-terminal and type
into it, so the suite can check the real input path (neo-blessed reading raw
bytes from a tty), which --render-once never exercises. Nothing here reads
the screen back beyond waiting for a marker text; the checks live in the
files the board and its fakes write (the opener log, the upgrade log, the
key log).

usage: pty-keys.py [--rows N] [--cols N] [--term TERM] [--capture FILE]
                   [--timeout SECONDS] ACTION... -- COMMAND ARG...

actions, run in order:
  send:<text>            write these bytes to the terminal; \\r \\n \\t \\x1b
                         escapes are decoded (send:\\r is one carriage return)
  wait:<needle>          pump output until the text the program has written
                         since the last send, with every escape sequence and
                         every whitespace character removed, contains needle
                         (the library repaints only changed cells, so a phrase
                         arrives without its spaces); --timeout bounds it
  sleep:<seconds>        pump output for this long
  exit                   wait for the program to exit (--timeout bounds it)

The raw bytes read back go to --capture when given. Exit status: 0 when every
wait was met and the program exited by itself, 3 on a wait timeout, 4 when it
had to be killed; a report of each action goes to stdout either way.
"""
import argparse
import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time

ESCAPES = re.compile(
    rb'\x1b\[[0-9;?]*[ -/]*[@-~]'  # CSI sequences (cursor moves, colours, modes)
    rb'|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)'  # OSC (window title)
    rb'|\x1b[()][0-9A-Za-z]'  # charset designations
    rb'|\x1b[=>78HM]'  # keypad modes, save/restore cursor
    rb'|[\x0e\x0f]'  # shift in / shift out
)


def clean(buf):
    return re.sub(rb'\s+', b'', ESCAPES.sub(b'', buf))


def decode_send(text):
    return text.encode('utf-8').decode('unicode_escape').encode('latin-1')


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument('--rows', type=int, default=40)
    ap.add_argument('--cols', type=int, default=160)
    ap.add_argument('--term', default='xterm-256color')
    ap.add_argument('--capture', default=None)
    ap.add_argument('--timeout', type=float, default=15.0)
    ap.add_argument('rest', nargs=argparse.REMAINDER)
    args = ap.parse_args()
    rest = args.rest
    if '--' not in rest:
        sys.stderr.write('pty-keys.py: expected ACTION... -- COMMAND ARG...\n')
        return 2
    sep = rest.index('--')
    actions, cmd = rest[:sep], rest[sep + 1:]
    if not cmd:
        sys.stderr.write('pty-keys.py: no command after --\n')
        return 2

    pid, fd = pty.fork()
    if pid == 0:
        fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', args.rows, args.cols, 0, 0))
        os.environ['TERM'] = args.term
        os.execvp(cmd[0], cmd)

    captured = bytearray()
    exited = [None]  # the wait status once the child is gone

    def child_gone():
        if exited[0] is not None:
            return True
        got, status = os.waitpid(pid, os.WNOHANG)
        if got == pid:
            exited[0] = status
            return True
        return False

    def pump(until):
        # Read whatever arrives until the deadline; stop early once the child
        # has exited and its output is drained.
        while True:
            now = time.time()
            if now >= until:
                return
            ready, _, _ = select.select([fd], [], [], min(0.05, max(0.0, until - now)))
            if fd in ready:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    data = b''
                if data:
                    captured.extend(data)
                    continue
                if child_gone():
                    return
            elif child_gone():
                # Drain once more in case output landed between the checks.
                ready, _, _ = select.select([fd], [], [], 0)
                if fd not in ready:
                    return

    status = 0
    since = 0  # offset of the output that followed the last send
    for action in actions:
        kind, _, arg = action.partition(':')
        if kind == 'send':
            since = len(captured)
            os.write(fd, decode_send(arg))
            print(f'send {arg!r}')
        elif kind == 'wait':
            needle = arg.encode('utf-8')
            deadline = time.time() + args.timeout
            while needle not in clean(bytes(captured[since:])):
                if time.time() >= deadline or (child_gone() and fd not in select.select([fd], [], [], 0)[0]):
                    print(f'wait {arg!r}: not seen within {args.timeout}s')
                    status = 3
                    break
                pump(min(deadline, time.time() + 0.1))
            else:
                print(f'wait {arg!r}: seen')
            if status:
                break
        elif kind == 'sleep':
            pump(time.time() + float(arg))
            print(f'sleep {arg}')
        elif kind == 'exit':
            deadline = time.time() + args.timeout
            while not child_gone() and time.time() < deadline:
                pump(time.time() + 0.1)
            if child_gone():
                print(f'exit: status {exited[0]}')
            else:
                print(f'exit: still running after {args.timeout}s')
                status = 3
        else:
            sys.stderr.write(f'pty-keys.py: unknown action {action!r}\n')
            status = 2
            break

    if not child_gone():
        # Give the program a moment, then make sure the terminal is released.
        pump(time.time() + 1.0)
        if not child_gone():
            os.kill(pid, signal.SIGTERM)
            pump(time.time() + 2.0)
            if not child_gone():
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
            print('killed the program')
            status = status or 4
    os.close(fd)
    if args.capture:
        with open(args.capture, 'wb') as f:
            f.write(captured)
    print(f'captured {len(captured)} bytes')
    return status


if __name__ == '__main__':
    sys.exit(main())
