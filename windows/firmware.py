#!/usr/bin/env python3
"""Admit this host's matching AMD VBIOS from its ACPI VFCT into operator storage."""

import argparse
import hashlib
import json
import struct
import subprocess
import uuid
from pathlib import Path

from vm import BDF


def extract_vbios(table, bdf, vendor, device):
    if not BDF.fullmatch(bdf) or not bdf.startswith('0000:'):
        raise ValueError('VFCT matching requires a complete PCI address in segment zero')
    if len(table) < 76 or table[:4] != b'VFCT':
        raise ValueError('invalid VFCT header')
    length = struct.unpack_from('<I', table, 4)[0]
    if length != len(table) or sum(table) % 256:
        raise ValueError('VFCT length or checksum mismatch')
    position = struct.unpack_from('<I', table, 52)[0]
    library = struct.unpack_from('<I', table, 56)[0]
    end = library if library else length
    if library and not position < library <= length:
        raise ValueError('invalid VFCT library offset')
    if position < 76 or position + 28 > length:
        raise ValueError('invalid VFCT image offset')
    _, bus, slot = bdf.split(':')
    number, function = slot.split('.')
    identity = (int(bus, 16), int(number, 16), int(function, 16), vendor, device)
    matches = []
    while position + 28 <= end:
        fields = struct.unpack_from('<IIIHHHHII', table, position)
        position += 28
        size = fields[-1]
        if not any(fields):
            break
        if not size or position + size > end:
            raise ValueError('invalid VFCT image length')
        image = table[position:position + size]
        position += size
        if fields[:5] == identity:
            if image[:2] != b'\x55\xaa' or sum(image) % 256:
                raise ValueError('native VBIOS header or checksum mismatch')
            matches.append(image)
    if len(matches) != 1:
        raise ValueError('VFCT must contain exactly one image matching the supplied GPU')
    return matches[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--gpu', required=True)
    parser.add_argument('--vfct', type=Path, default=Path('/sys/firmware/acpi/tables/VFCT'))
    parser.add_argument('--cache', type=Path, required=True)
    args = parser.parse_args()
    if not BDF.fullmatch(args.gpu):
        raise ValueError('invalid GPU PCI address')
    gpu = Path('/sys/bus/pci/devices') / args.gpu
    vendor = int((gpu / 'vendor').read_text().strip(), 16)
    device = int((gpu / 'device').read_text().strip(), 16)
    table = args.vfct.read_bytes()
    image = extract_vbios(table, args.gpu, vendor, device)
    fs = subprocess.check_output(['findmnt', '--noheadings', '--output', 'FSTYPE', '--target', str(args.cache)], text=True).split()
    if set(fs) - {'autofs'} not in ({'nfs'}, {'nfs4'}):
        raise ValueError('firmware cache must be on mounted NFS')
    digest = hashlib.sha256(image).hexdigest()
    entry = args.cache / 'media/firmware/sha256' / digest
    entry.mkdir(parents=True, exist_ok=True)
    target = entry / 'vbios.rom'
    if target.exists():
        if hashlib.sha256(target.read_bytes()).hexdigest() != digest:
            raise ValueError('cached VBIOS checksum mismatch')
    else:
        temporary = entry / ('.incoming-' + uuid.uuid4().hex)
        temporary.write_bytes(image)
        temporary.chmod(0o444)
        temporary.replace(target)
    source = hashlib.sha256(table).hexdigest()
    receipt = {'schema': 1, 'source': 'host ACPI VFCT', 'vfct_sha256': source,
               'gpu': args.gpu, 'vendor': f'{vendor:04x}', 'device': f'{device:04x}',
               'sha256': digest, 'bytes': len(image)}
    (entry / f'vfct-{source}.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'path': str(target), 'sha256': digest}))


if __name__ == '__main__':
    main()
