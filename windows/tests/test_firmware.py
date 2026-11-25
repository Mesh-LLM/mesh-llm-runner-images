import importlib.util
import struct
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
SPEC = importlib.util.spec_from_file_location('windows_firmware', ROOT / 'firmware.py')
firmware = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(firmware)


def table(device=0x1586, image_size=None):
    image = bytearray(b'\x55\xaa' + bytes(509))
    image.append((-sum(image)) % 256)
    header = bytearray(76)
    header[:4] = b'VFCT'
    entry = struct.pack('<IIIHHHHII', 0xc2, 0, 0, 0x1002, device, 0, 0, 1,
                        len(image) if image_size is None else image_size)
    blob = header + entry + image
    struct.pack_into('<I', blob, 4, len(blob))
    struct.pack_into('<I', blob, 52, 76)
    blob[9] = (-sum(blob)) % 256
    return bytes(blob), bytes(image)


class NativeFirmwareAdmission(unittest.TestCase):
    def test_extracts_only_the_exact_host_pci_identity(self):
        blob, image = table()
        self.assertEqual(firmware.extract_vbios(blob, '0000:c2:00.0', 0x1002, 0x1586), image)
        with self.assertRaisesRegex(ValueError, 'exactly one'):
            firmware.extract_vbios(blob, '0000:c3:00.0', 0x1002, 0x1586)

    def test_rejects_corrupt_table_and_foreign_gpu(self):
        blob, _ = table()
        damaged = bytearray(blob)
        damaged[-1] ^= 1
        with self.assertRaisesRegex(ValueError, 'checksum'):
            firmware.extract_vbios(damaged, '0000:c2:00.0', 0x1002, 0x1586)
        with self.assertRaisesRegex(ValueError, 'exactly one'):
            firmware.extract_vbios(blob, '0000:c2:00.0', 0x1002, 0x9999)

    def test_rejects_image_bounds_before_reading_firmware(self):
        blob, _ = table(image_size=100000)
        with self.assertRaisesRegex(ValueError, 'image length'):
            firmware.extract_vbios(blob, '0000:c2:00.0', 0x1002, 0x1586)


if __name__ == '__main__':
    unittest.main()
