#!/usr/bin/env python3
"""Drive install.sh on a pty and answer the prompts it shows.

install.sh refuses to ask anything without a terminal -- it checks isatty on
both stdin and stdout before it will prompt -- so the only honest way to test
the prompt is to give it one. pty.fork() puts the child in a session of its
own with the pty as its controlling terminal, which is exactly what those two
checks want, and it leaves us free to waitpid for the real exit status.

Usage: drive_prompts.py KEYS -- COMMAND [ARGS...]

KEYS is one answer per prompt, separated by newlines. An answer may be empty,
which is what pressing Enter sends. A line holding a single EOT character
sends end-of-input at the prompt instead of an answer, which is how the
"input ran out" path gets reached.

Answers are written as each prompt appears rather than all at once, so a
child that never prompts is reported through its exit status instead of
being waited on forever.

Everything the child writes comes back on stdout, both streams merged,
because a pty has only one. Diagnostics from this driver go to stderr.
"""

import errno
import os
import pty
import select
import sys
import time

# The one line of install.sh's prompt that nothing else prints, so its arrival
# means the child has reached a prompt and is about to read.
PROMPT_MARK = b"? [Y]es (default)"
# Separates the answers in KEYS. A prompt answer never contains a newline.
KEY_SEP = b"\n"
# End of input at the prompt. Sending the character rather than closing the
# master is deliberate: closing it also pulls the terminal away from a child
# that has not finished printing its summary.
EOT = b"\x04"

TIMEOUT = 20.0

EXIT_USAGE = 2
EXIT_HUNG = 3


def die(message, code=EXIT_USAGE):
    sys.stderr.write("drive_prompts.py: %s\n" % message)
    sys.exit(code)


def answers_from(keys):
    """KEYS as a list of answers, one per prompt."""
    if not keys:
        return []
    answers = keys.split(KEY_SEP)
    if answers and answers[-1] == b"":
        answers.pop()
    return answers


def as_wire_bytes(answer):
    """One answer as it goes down the wire."""
    if answer == EOT:
        return EOT
    return answer + KEY_SEP


def exchange(master, answers, deadline):
    """Answer prompts until the child lets go of the terminal.

    Returns everything the child wrote. EIO on the master is how a pty says
    every writer has gone, which is how we learn the child has finished.
    """
    out = bytearray()
    sent = 0

    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return out, False

        ready, _, _ = select.select([master], [], [], min(remaining, 0.2))
        if not ready:
            continue

        try:
            chunk = os.read(master, 65536)
        except OSError as exc:
            if exc.errno == errno.EIO:
                return out, True
            raise
        if not chunk:
            return out, True

        out += chunk

        # Counting over the whole buffer rather than the chunk means a prompt
        # split across two reads still counts once, and only once complete.
        while sent < out.count(PROMPT_MARK):
            os.write(master, as_wire_bytes(answers[sent]))
            sent += 1

    return out, True  # pragma: no cover


def reap(pid):
    """Wait for the child, killing it if it will not go."""
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        try:
            finished, status = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            return None
        if finished == pid:
            return status
        time.sleep(0.05)

    os.kill(pid, 9)
    os.waitpid(pid, 0)
    return None


def main(argv):
    if len(argv) < 4 or argv[2] != "--":
        die(__doc__ or "usage: drive_prompts.py KEYS -- COMMAND [ARGS...]")
    keys = argv[1].encode()
    command = argv[3:]
    answers = answers_from(keys)

    pid, master = pty.fork()
    if pid == 0:
        # Child: pty.fork has already made the pty our stdin, stdout and
        # stderr, so exec is all that is left.
        try:
            os.execvp(command[0], command)
        except OSError:
            os._exit(127)

    out, finished = exchange(master, answers, time.monotonic() + TIMEOUT)

    try:
        os.close(master)
    except OSError:
        pass

    status = reap(pid)

    sys.stdout.buffer.write(bytes(out))
    sys.stdout.buffer.flush()

    if not finished:
        die("the child was still waiting after %.0fs, having shown %d prompt(s) "
            "and been given %d answer(s)"
            % (TIMEOUT, out.count(PROMPT_MARK), len(answers)),
            code=EXIT_HUNG)
    if status is None:
        die("the child did not exit")

    return os.waitstatus_to_exitcode(status)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
