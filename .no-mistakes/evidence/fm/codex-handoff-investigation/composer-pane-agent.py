#!/usr/bin/env python3
"""A real interactive pane process that renders a Codex-style bordered composer.

Two modes, both real terminal behaviour on a real pty:
  AGENT_MODE=swallow  Enter is read and DISCARDED, so text typed into the
                      composer stays visible there - a swallowed submit.
  AGENT_MODE=submit   Enter clears the composer and echoes the line into the
                      transcript above it - a submit that lands.
"""
import os
import sys
import termios
import tty

MODE = os.environ.get("AGENT_MODE", "swallow")
W = max(20, os.get_terminal_size().columns - 4)
RULE = "─" * (W + 2)
buf = ""
log = []


def render():
    out = ["\x1b[2J\x1b[H", "codex-like pane agent  (mode=%s)\r\n\r\n" % MODE]
    for line in log[-8:]:
        out.append("  • %s\r\n" % line[:W])
    out.append("\r\n╭%s╮\r\n" % RULE)
    out.append("│ %-*.*s │\r\n" % (W, W, buf))
    out.append("╰%s╯" % RULE)
    # park the real cursor inside the composer row, just after the text
    out.append("\x1b[1A\x1b[%dG" % (3 + min(len(buf), W)))
    sys.stdout.write("".join(out))
    sys.stdout.flush()


fd = sys.stdin.fileno()
saved = termios.tcgetattr(fd)
try:
    tty.setraw(fd)
    render()
    while True:
        ch = sys.stdin.read(1)
        if ch == "" or ch == "\x04":
            break
        if ch in ("\r", "\n"):
            if MODE == "submit":
                if buf:
                    log.append(buf)
                buf = ""
                render()
            # swallow mode: the Enter is consumed and nothing happens
            continue
        if ch in ("\x7f", "\b"):
            buf = buf[:-1]
            render()
            continue
        if ch == "\x1b":
            continue
        if ch.isprintable():
            buf += ch
            render()
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, saved)
