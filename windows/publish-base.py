#!/usr/bin/env python3
"""Compress a completed local Windows base and publish a verified NFS cache entry."""

import argparse
import json
import os
import re
import shutil
import subprocess
import tempfile
import uuid
from pathlib import Path

from vm import sha256, storage_manifest


def publish(source, target, work_root):
    if target.exists():
        raise ValueError('refusing to replace a published base')
    source = source.resolve(strict=True)
    receipt = json.loads((source / 'base.json').read_text())
    if receipt.get('schema') != 1 or storage_manifest(source / 'storage') != receipt.get('files'):
        raise ValueError('source base receipt mismatch')
    image = receipt['launcher_image']
    if not re.fullmatch(r'sha256:[a-f0-9]{64}', image):
        raise ValueError('source must identify the exact prepared launcher image')
    filesystem = subprocess.check_output(['findmnt', '--noheadings', '--output', 'FSTYPE', '--target', str(target.parent)], text=True).split()
    if set(filesystem) - {'autofs'} not in ({'nfs'}, {'nfs4'}):
        raise ValueError('publication target must be on mounted NFS')
    disks = [name for name in ['data.img', 'data.qcow2'] if (source / 'storage' / name).is_file()]
    if len(disks) != 1:
        raise ValueError('source must contain one raw or QCOW2 Windows data disk')
    disk_format = 'raw' if disks[0].endswith('.img') else 'qcow2'
    stage = target.parent / ('.incoming-' + uuid.uuid4().hex)
    try:
        with tempfile.TemporaryDirectory(prefix='mesh-windows-publish-', dir=work_root) as temporary:
            work = Path(temporary)
            storage = work / 'storage'
            storage.mkdir()
            for path in (source / 'storage').iterdir():
                if path.name != disks[0]:
                    shutil.copyfile(path, storage / path.name)
            docker = ['docker', 'run', '--rm', '--user', str(os.getuid()), '--network', 'none',
                      '--mount', f'type=bind,src={source}/storage,dst=/source,readonly',
                      '--mount', f'type=bind,src={storage},dst=/target', '--entrypoint', 'qemu-img', image]
            subprocess.run(docker + ['convert', '-f', disk_format, '-O', 'qcow2', '-c', '-o', 'compression_type=zstd',
                                    '/source/' + disks[0], '/target/data.qcow2'], check=True)
            subprocess.run(docker + ['compare', '-f', disk_format, '-F', 'qcow2',
                                    '/source/' + disks[0], '/target/data.qcow2'], check=True)
            if storage_manifest(source / 'storage') != receipt['files']:
                raise ValueError('source changed during conversion')
            receipt['derivation'] = {'parent_receipt_sha256': sha256(source / 'base.json'),
                                     'method': 'qemu-img convert -c compression_type=zstd', 'virtual_disk_compare': 'equal'}
            receipt['files'] = storage_manifest(storage)
            subprocess.run(['docker', 'image', 'save', image, '--output', str(work / 'launcher.tar')], check=True)
            receipt['launcher_archive_sha256'] = sha256(work / 'launcher.tar')
            (work / 'base.json').write_text(json.dumps(receipt, indent=2) + '\n')
            shutil.copytree(work, stage)
            if storage_manifest(stage / 'storage') != receipt['files'] or sha256(stage / 'launcher.tar') != receipt['launcher_archive_sha256']:
                raise ValueError('published NFS bytes differ from the prepared artifacts')
            stage.rename(target)
        print(target)
    finally:
        if stage.exists():
            shutil.rmtree(stage)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--target', type=Path, required=True)
    parser.add_argument('--work-root', type=Path, default=Path('/var/tmp'))
    args = parser.parse_args()
    publish(args.source, args.target, args.work_root)
