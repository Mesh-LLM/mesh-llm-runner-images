#!/usr/bin/env python3
"""Admit a supplied Windows ISO into a checksum-addressed shared media cache."""

import argparse
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlsplit


def digest(path):
    state = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            state.update(block)
    return state.hexdigest()


def verify(path, expected):
    if path.is_symlink() or not path.is_file() or digest(path) != expected:
        raise ValueError("Windows ISO checksum mismatch; no cached media was admitted")


def require_nfs(path):
    parent = path.resolve()
    while not parent.exists():
        parent = parent.parent
    result = subprocess.run(["findmnt", "--noheadings", "--output", "FSTYPE", "--target", str(parent)],
                            check=True, capture_output=True, text=True)
    filesystems = set(result.stdout.split()) - {"autofs"}
    if filesystems not in ({"nfs"}, {"nfs4"}):
        raise ValueError("cache path is not on a mounted NFS filesystem")


def download(url_file, partial):
    url = url_file.read_text().strip()
    parts = urlsplit(url)
    if (parts.scheme != "https" or not parts.hostname or parts.username or parts.password
            or any(ord(char) < 32 for char in url)):
        raise ValueError("ISO download requires a single HTTPS URL")
    # Send the temporary link on stdin instead of exposing its session/query
    # parameters in command arguments, build logs or the durable media receipt.
    config = 'url = "' + url.replace("\\", "\\\\").replace('"', '\\"') + '"\n'
    result = subprocess.run([
        "curl", "--fail", "--location", "--continue-at", "-", "--silent", "--show-error",
        "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "30",
        "--max-time", "3600", "--retry", "3", "--retry-delay", "5",
        "--output", str(partial), "--config", "-",
    ], input=config, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f"ISO download failed (curl exit {result.returncode}); partial media retained. "
                           "If the Microsoft link expired, supply a fresh link for the same ISO and checksum.")


def admit(args):
    if not re.fullmatch(r"[a-f0-9]{64}", args.sha256):
        raise ValueError("--sha256 must be the trusted SHA-256 of the selected Windows ISO")
    if args.require_nfs:
        require_nfs(args.cache)
    objects = args.cache.resolve() / "media/sha256"
    objects.parent.mkdir(parents=True, exist_ok=True)
    try:
        # NFS exports can remap the publisher's UID. A sticky directory would
        # then prevent that publisher from renaming/removing its own entries.
        objects.mkdir(mode=0o777)
        objects.chmod(0o777)
    except FileExistsError:
        pass
    entry = objects / args.sha256
    entry.mkdir(exist_ok=True)
    destination = entry / "windows11.iso"
    # Completed objects are published by rename and always verified before
    # reuse. Consumers with different numeric UIDs need no cache write access.
    if destination.exists():
        verify(destination, args.sha256)
        return destination
    with (entry / ".lock").open("a+b") as lock:
        deadline = time.monotonic() + 300
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise RuntimeError("timed out waiting for the ISO cache publisher")
                time.sleep(1)
        if destination.exists():
            verify(destination, args.sha256)
            return destination
        partial = entry / "windows11.iso.part"
        if args.source:
            source = args.source.resolve(strict=True)
            verify(source, args.sha256)
            shutil.copyfile(source, partial)
        elif args.url_file:
            download(args.url_file, partial)
        else:
            raise ValueError("ISO is not cached; provide --source or --url-file for initial population")
        try:
            verify(partial, args.sha256)
        except ValueError:
            partial.unlink(missing_ok=True)
            raise
        partial.chmod(0o444)
        receipt = {"schema": 1, "sha256": args.sha256, "size_bytes": partial.stat().st_size}
        temporary_receipt = entry / "media.json.tmp"
        temporary_receipt.write_text(json.dumps(receipt, indent=2) + "\n")
        temporary_receipt.chmod(0o444)
        temporary_receipt.replace(entry / "media.json")
        partial.replace(destination)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", required=True, type=Path)
    pin = json.loads(Path(__file__).with_name("media.json").read_text())
    parser.add_argument("--sha256", type=str.lower, default=pin["sha256"],
                        help="trusted ISO digest; defaults to the selected media.json pin")
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--source", type=Path, help="existing ISO to admit or replicate")
    source.add_argument("--url-file", type=Path, help="private file containing a fresh Microsoft download URL")
    parser.add_argument("--require-nfs", action="store_true")
    print(admit(parser.parse_args()))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        sys.exit(str(error) or "interrupted")
