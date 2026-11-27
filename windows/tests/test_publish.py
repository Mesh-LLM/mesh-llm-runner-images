import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
SPEC = importlib.util.spec_from_file_location('publish_base', ROOT / 'publish-base.py')
publisher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publisher)


class PublicationAdmission(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / 'source'
        (self.source / 'storage').mkdir(parents=True)
        (self.source / 'storage/data.qcow2').write_bytes(b'fixture')
        self.receipt = {'schema': 1, 'launcher_image': 'sha256:' + 'a' * 64,
                        'files': publisher.storage_manifest(self.source / 'storage')}
        (self.source / 'base.json').write_text(json.dumps(self.receipt))

    def test_tampered_source_cannot_start_conversion(self):
        (self.source / 'storage/data.qcow2').write_bytes(b'changed')
        with patch.object(publisher.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'receipt mismatch'):
                publisher.publish(self.source, self.root / 'target', self.root)
        run.assert_not_called()
        self.assertFalse((self.root / 'target').exists())

    def test_existing_publication_is_never_replaced(self):
        target = self.root / 'target'
        target.mkdir()
        (target / 'receipt').write_text('preserve')
        with self.assertRaisesRegex(ValueError, 'refusing to replace'):
            publisher.publish(self.root / 'missing', target, self.root)
        self.assertEqual((target / 'receipt').read_text(), 'preserve')

    def test_local_target_cannot_become_an_nfs_cache_fallback(self):
        for image in ['sha256:' + 'a' * 64, 'registry.example/launcher@sha256:' + 'a' * 64]:
            with self.subTest(image=image):
                self.receipt['launcher_image'] = image
                (self.source / 'base.json').write_text(json.dumps(self.receipt))
                with patch.object(publisher.subprocess, 'check_output', return_value='autofs\next4\n'), \
                        patch.object(publisher.subprocess, 'run') as run:
                    with self.assertRaisesRegex(ValueError, 'mounted NFS'):
                        publisher.publish(self.source, self.root / 'target', self.root)
                run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
