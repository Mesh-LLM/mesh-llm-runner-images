#!/usr/bin/env python3
"""Run one build, stream its output, and retain bounded output plus its outcome."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import signal
import sys
import time

MAX_LOG = 8 * 1024 * 1024


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a build command is required")
    args.log.parent.mkdir(parents=True, exist_ok=True)
    args.state.parent.mkdir(parents=True, exist_ok=True)
    if args.state.exists() or args.state.is_symlink():
        parser.error("invocation state already exists")
    # Reserve the log before starting a command; an existing path never launches a build.
    with args.log.open("xb") as log:
        started = time.monotonic()
        # No shell: arguments are the exact invocation being measured.
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        retained = 0
        def interrupted(signum, _frame):
            raise InterruptedError(f"capture interrupted by signal {signum}")
        signal.signal(signal.SIGTERM, interrupted)
        try:
            while True:
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    break
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
                # Keep one extra byte so the receipt validator rejects overflow;
                # keep draining so a full pipe cannot deadlock the build.
                piece = chunk[:max(0, MAX_LOG + 1 - retained)]
                log.write(piece)
                retained += len(piece)
            status = process.wait()
        except BaseException:
            # A broken output stream, write failure, or cancellation cannot orphan a build.
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            raise
        finally:
            process.stdout.close()
    state = {"outcome": "success" if status == 0 else "failure",
             "wrapper_elapsed_seconds": round(time.monotonic() - started, 6)}
    temporary = args.state.with_suffix(".tmp")
    temporary.write_text(json.dumps(state) + "\n")
    temporary.replace(args.state)
    return status if status >= 0 else 128 - status


if __name__ == "__main__":
    sys.exit(main())
