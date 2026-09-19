#!/usr/bin/env python3
# Stand-in worker TUI for live validation: draws a bordered composer like a
# real agent harness, echoes typed text into it, and SWALLOWS Enter (the
# failure mode under test). Every keystroke it receives is appended to the
# key log given as argv[1], so the test can prove which keys firstmate really
# sent to the pane. SIGUSR1 clears the composer (an operator clearing the line).
import os, signal, sys, termios, tty
log_path = sys.argv[1]
RULE = "─" * 40
buf = []
def log(msg):
    with open(log_path, "a") as f:
        f.write(msg + "\n")
def draw():
    text = "".join(buf)
    inner = (text[:38]).ljust(38)
    sys.stdout.write("\x1b[H\x1b[2J")
    sys.stdout.write("╭" + RULE + "╮\r\n")
    sys.stdout.write("│ " + inner + " │\r\n")
    sys.stdout.write("╰" + RULE + "╯\r\n")
    sys.stdout.write("\x1b[2;%dH" % (3 + min(len(text), 38)))
    sys.stdout.flush()
def on_usr1(signum, frame):
    buf.clear(); log("SIGUSR1: composer cleared by operator"); draw()
signal.signal(signal.SIGUSR1, on_usr1)
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setraw(fd)
log("started pid=%d" % os.getpid())
draw()
try:
    while True:
        try:
            ch = os.read(fd, 1)
        except InterruptedError:
            continue
        if not ch:
            break
        b = ch[0]
        if b in (13, 10):
            log("KEY Enter (SWALLOWED) composer=%r" % "".join(buf))
        elif b == 0x15:
            log("KEY C-u (composer cleared)"); buf.clear()
        elif b == 0x1b:
            log("KEY Escape")
        elif b == 0x03:
            log("KEY C-c (exit)"); break
        elif b == 0x7f:
            log("KEY BSpace"); buf and buf.pop()
        elif b == 0x01:
            log("KEY C-a")
        elif b == 0x0b:
            log("KEY C-k")
        elif 32 <= b < 127:
            buf.append(chr(b))
        else:
            log("KEY byte=%d" % b)
        draw()
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
