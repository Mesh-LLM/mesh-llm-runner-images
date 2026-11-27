#!/usr/bin/env python3
"""Admit a supplied Windows ISO into a checksum-addressed shared media cache."""

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import time
import uuid
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
        "--output", f'/dev/fd/{partial.fileno()}', "--config", "-",
    ], input=config, text=True, capture_output=True, pass_fds=(partial.fileno(),))
    if result.returncode:
        raise RuntimeError(f"ISO download failed (curl exit {result.returncode}); partial media retained. "
                           "If the Microsoft link expired, supply a fresh link for the same ISO and checksum.")


def open_regular(directory, name, flags, mode=0o600):
    descriptor = os.open(name, flags | os.O_NOFOLLOW | os.O_NONBLOCK, mode, dir_fd=directory)
    state = os.fstat(descriptor)
    if not stat.S_ISREG(state.st_mode) or state.st_nlink != 1:
        os.close(descriptor)
        raise ValueError('ISO cache staging must be a regular file with no hard links')
    return descriptor


def stream_digest(stream):
    stream.seek(0)
    state = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b''):
        state.update(block)
    return state.hexdigest()


@contextmanager
def staging_iso(directory, expected):
    name = 'windows11.iso.part'
    try:
        original = os.fdopen(open_regular(directory, name, os.O_RDONLY), 'rb')
    except FileNotFoundError:
        original = None
    try:
        if original and stream_digest(original) == expected:
            yield original, True
            return
        temporary = '.iso-' + uuid.uuid4().hex
        try:
            with os.fdopen(open_regular(directory, temporary, os.O_CREAT | os.O_EXCL | os.O_RDWR), 'w+b') as stream:
                if original:
                    # Never chmod or overwrite the old read-only partial. A fresh
                    # descriptor owns every validation, write and permission change.
                    original.seek(0)
                    shutil.copyfileobj(original, stream)
                stream.flush()
                os.replace(temporary, name, src_dir_fd=directory, dst_dir_fd=directory)
                yield stream, False
        finally:
            try:
                os.unlink(temporary, dir_fd=directory)
            except FileNotFoundError:
                pass
    finally:
        if original:
            original.close()


def publish_receipt(directory, receipt):
    name = '.receipt-' + uuid.uuid4().hex
    try:
        with os.fdopen(open_regular(directory, name, os.O_CREAT | os.O_EXCL | os.O_WRONLY), 'w') as stream:
            json.dump(receipt, stream, indent=2)
            stream.write('\n')
            stream.flush()
            os.fchmod(stream.fileno(), 0o444)
        os.replace(name, 'media.json', src_dir_fd=directory, dst_dir_fd=directory)
    finally:
        try:
            os.unlink(name, dir_fd=directory)
        except FileNotFoundError:
            pass


def populate(directory, args):
    with staging_iso(directory, args.sha256) as (stream, complete):
        if not complete:
            if args.source:
                source = args.source.resolve(strict=True)
                verify(source, args.sha256)
                stream.seek(0)
                stream.truncate()
                with source.open('rb') as supplied:
                    shutil.copyfileobj(supplied, stream)
                stream.flush()
            elif args.url_file:
                download(args.url_file, stream)
            else:
                raise ValueError('ISO is not cached; provide --source or --url-file for initial population')
        if stream_digest(stream) != args.sha256:
            os.unlink('windows11.iso.part', dir_fd=directory)
            raise ValueError('Windows ISO checksum mismatch; no cached media was admitted')
        state = os.fstat(stream.fileno())
        current = os.stat('windows11.iso.part', dir_fd=directory, follow_symlinks=False)
        if (state.st_dev, state.st_ino) != (current.st_dev, current.st_ino) or state.st_nlink != 1:
            raise ValueError('ISO staging changed during publication')
        os.fchmod(stream.fileno(), 0o444)
        publish_receipt(directory, {'schema': 1, 'sha256': args.sha256, 'size_bytes': state.st_size})
        os.replace('windows11.iso.part', 'windows11.iso', src_dir_fd=directory, dst_dir_fd=directory)


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
    directory = os.open(entry, os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        lock_descriptor = open_regular(directory, '.lock', os.O_CREAT | os.O_RDWR)
    except Exception:
        os.close(directory)
        raise
    with os.fdopen(lock_descriptor, 'a+b') as lock:
        try:
            return admit_locked(directory, destination, args, lock)
        finally:
            os.close(directory)


def admit_locked(directory, destination, args, lock):
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
    populate(directory, args)
    verify(destination, args.sha256)
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
