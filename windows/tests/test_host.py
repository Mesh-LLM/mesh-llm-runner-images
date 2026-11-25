import argparse
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
SPEC = importlib.util.spec_from_file_location('windows_host', ROOT / 'host.py')
host = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(host)


class Recovery(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        boot = self.root / 'boot'
        boot.write_text('current-boot')
        patcher = patch.object(host, 'BOOT_ID', boot)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.config_file = self.root / 'agent.toml'
        self.config_file.write_text('enabled = false\n')
        self.config = {'jy_config': str(self.config_file), 'backend': 'cuda'}
        self.journal = {'lease': 'run_test', 'bindings': {}, 'services': [], 'consoles': [],
                        'paused_config': host.digest(self.config_file)}

    def test_changed_operator_settings_keep_host_paused_after_restoration(self):
        self.config_file.write_text('enabled = false\ndrain = true\n')
        with patch.object(host, 'STATE', self.root), patch.object(host, 'command', return_value=''), \
                patch.object(host, 'native_probe'), patch.object(host, 'jy') as jy:
            with self.assertRaisesRegex(RuntimeError, 'operator reconciliation'):
                host.restore(self.config, self.journal)
        self.assertEqual(jy.call_args_list[0].args[1], 'off')
        self.assertFalse(any(call.args[1] == 'on' for call in jy.call_args_list))

    def test_native_discovery_failure_cannot_resume_scheduler(self):
        with patch.object(host, 'STATE', self.root), patch.object(host, 'command', return_value=''), \
                patch.object(host, 'native_probe', side_effect=RuntimeError('GPU absent')), \
                patch.object(host, 'jy') as jy:
            with self.assertRaisesRegex(RuntimeError, 'GPU absent'):
                host.restore(self.config, self.journal)
        jy.assert_not_called()

    def test_windows_amd_without_guest_release_cannot_rebind_or_resume(self):
        work = self.root / 'run_test'
        (work / 'shared/input').mkdir(parents=True)
        (work / 'shared/input/driver.json').write_text('{}')
        gpu = self.root / '0000:c2:00.0'
        gpu.mkdir()
        (gpu / 'device').write_text('0x1586')
        self.config.update(backend='rocm', gpu=gpu.name)
        self.journal['work'] = str(work)
        with patch.object(host, 'STATE', self.root), patch.object(host, 'PCI', self.root), \
                patch.object(host, 'command', return_value=''), patch.object(host, 'jy') as jy, \
                patch.object(host, 'set_driver') as bind:
            with self.assertRaisesRegex(RuntimeError, 'retain VFIO quarantine'):
                host.restore(self.config, self.journal)
        bind.assert_not_called()
        jy.assert_not_called()

    def test_amd_release_proof_must_match_the_assigned_device(self):
        work = self.root / 'run_test'
        (work / 'shared/input').mkdir(parents=True)
        (work / 'shared/output').mkdir()
        (work / 'shared/input/driver.json').write_text('{}')
        gpu = self.root / '0000:c2:00.0'
        gpu.mkdir()
        (gpu / 'device').write_text('0x1586')
        self.config.update(backend='rocm', gpu=gpu.name)
        self.journal['work'] = str(work)
        receipt = work / 'shared/output/gpu-release.json'
        with patch.object(host, 'PCI', self.root):
            receipt.write_text(json.dumps({'PNPDeviceID': 'PCI\\VEN_1002&DEV_9999', 'ConfigManagerErrorCode': 22}))
            with self.assertRaisesRegex(RuntimeError, 'retain VFIO quarantine'):
                host.verify_amd_release(self.config, self.journal)
            receipt.write_text(json.dumps({'PNPDeviceID': 'PCI\\VEN_1002&DEV_1586&SUBSYS_test', 'ConfigManagerErrorCode': 22}))
            host.verify_amd_release(self.config, self.journal)

    def test_host_restart_requires_already_restored_bindings_and_native_discovery(self):
        work = self.root / 'run_test'
        (work / 'shared/input').mkdir(parents=True)
        (work / 'shared/input/driver.json').write_text('{}')
        gpu = self.root / '0000:c2:00.0'
        gpu.mkdir()
        (gpu / 'driver').symlink_to('/sys/bus/pci/drivers/amdgpu')
        self.config.update(backend='rocm', gpu=gpu.name)
        self.journal.update(work=str(work), owner={'boot': 'previous-boot'}, bindings={gpu.name: 'amdgpu'})
        with patch.object(host, 'PCI', self.root), patch.object(host, 'native_probe') as probe:
            host.verify_amd_release(self.config, self.journal)
            probe.assert_called_once_with(self.config)
            probe.side_effect = RuntimeError('native GPU absent')
            with self.assertRaisesRegex(RuntimeError, 'native GPU absent'):
                host.verify_amd_release(self.config, self.journal)

    def test_stops_only_owned_vms_before_restoring_bindings(self):
        calls = []
        self.journal['bindings'] = {'0000:01:00.0': 'nvidia'}
        device = self.root / '0000:01:00.0'
        device.mkdir()
        (device / 'driver_override').touch()
        host.save(self.root / 'active.json', self.journal)

        def command(*args, **kwargs):
            calls.append(args)
            return 'owned\n' if args[:3] == ('docker', 'ps', '-aq') else ''

        with patch.object(host, 'STATE', self.root), patch.object(host, 'PCI', self.root), \
                patch.object(host, 'command', command), patch.object(host, 'native_probe'), \
                patch.object(host, 'set_driver', side_effect=lambda *args: calls.append(('bind', *args))), \
                patch.object(host, 'jy') as jy:
            host.restore(self.config, self.journal)
        self.assertIn('label=mesh.windows.lease=run_test', calls[0])
        self.assertLess(calls.index(('docker', 'rm', '--force', 'owned')),
                        calls.index(('bind', '0000:01:00.0', 'nvidia')))
        jy.assert_called_once_with(self.config, 'on')
        self.assertFalse((self.root / 'active.json').exists())

    def test_dead_owner_or_reused_pid_is_not_a_live_lease(self):
        with patch.object(host, 'owner_identity', return_value={'pid': 22, 'start': 'new', 'boot': 'a'}):
            self.assertFalse(host.owner_alive({'pid': 22, 'start': 'old', 'boot': 'a'}))
        with patch.object(host, 'owner_identity', side_effect=FileNotFoundError):
            self.assertFalse(host.owner_alive({'pid': 22}))

    def test_failed_amd_binding_is_not_retried_by_recovery(self):
        work = self.root / 'run_test'
        (work / 'shared/input').mkdir(parents=True)
        (work / 'shared/output').mkdir()
        (work / 'shared/input/driver.json').write_text('{}')
        (work / 'shared/output/gpu-release.json').write_text(json.dumps({
            'PNPDeviceID': 'PCI\\VEN_1002&DEV_1586', 'ConfigManagerErrorCode': 22}))
        gpu = self.root / '0000:c2:00.0'
        gpu.mkdir()
        (gpu / 'device').write_text('0x1586')
        self.config.update(backend='rocm', gpu=gpu.name)
        self.journal.update(work=str(work), owner={'boot': 'current-boot'}, bindings={gpu.name: 'amdgpu'})
        with patch.object(host, 'STATE', self.root), patch.object(host, 'PCI', self.root), \
                patch.object(host, 'command', return_value=''), patch.object(host, 'jy') as jy, \
                patch.object(host, 'set_driver', side_effect=RuntimeError('bind failed')) as bind:
            with self.assertRaisesRegex(RuntimeError, 'bind failed'):
                host.restore(self.config, self.journal)
            saved = json.loads((self.root / 'active.json').read_text())
            self.assertEqual(saved['native_rebind_boot'], 'current-boot')
            with self.assertRaisesRegex(RuntimeError, 'without retry'):
                host.restore(self.config, saved)
        bind.assert_called_once_with(gpu.name, 'amdgpu')
        jy.assert_not_called()

    def test_restart_cannot_use_a_previous_boot_guest_receipt(self):
        work = self.root / 'run_test'
        (work / 'shared/input').mkdir(parents=True)
        (work / 'shared/output').mkdir()
        (work / 'shared/input/driver.json').write_text('{}')
        (work / 'shared/output/gpu-release.json').write_text(json.dumps({
            'PNPDeviceID': 'PCI\\VEN_1002&DEV_1586', 'ConfigManagerErrorCode': 22}))
        self.config.update(backend='rocm', gpu='0000:c2:00.0')
        self.journal.update(work=str(work), owner={'boot': 'previous-boot'},
                            bindings={'0000:c2:00.0': 'amdgpu'})
        with patch.object(host, 'PCI', self.root), patch.object(host, 'native_probe') as probe:
            with self.assertRaisesRegex(RuntimeError, 'without original AMD bindings'):
                host.verify_amd_release(self.config, self.journal)
        probe.assert_not_called()

    def test_partial_acquisition_retains_original_bindings_and_quarantine(self):
        self.config_file.write_text('enabled = true\ndrain = false\n')
        gpu = self.root / '0000:01:00.0'
        gpu.mkdir()
        (gpu / 'driver').symlink_to('/sys/bus/pci/drivers/nvidia')
        self.config.update(gpu=gpu.name)
        args = argparse.Namespace(gpu=gpu.name, lease='run_test', owner_pid=22, work=None)

        def pause(config, action):
            self.assertEqual(action, 'off')
            self.config_file.write_text('enabled = false\ndrain = false\n')

        def bind(*_):
            journal = json.loads((self.root / 'active.json').read_text())
            self.assertEqual(journal['bindings'], {gpu.name: 'nvidia'})
            self.assertEqual(journal['paused_config'], host.digest(self.config_file))
            raise RuntimeError('injected bind failure')

        with patch.object(host, 'STATE', self.root), patch.object(host, 'PCI', self.root), \
                patch.object(host, 'verify_reservation', return_value={'pid': 22}), \
                patch.object(host, 'gpu_devices', return_value=('12', [gpu.name])), \
                patch.object(host, 'native_probe'), patch.object(host, 'command'), \
                patch.object(host.subprocess, 'run', return_value=argparse.Namespace(returncode=1)), \
                patch.object(host, 'refuse_open_devices'), patch.object(host, 'jy', pause), \
                patch.object(host, 'set_driver', bind):
            with self.assertRaisesRegex(RuntimeError, 'injected bind failure'):
                host.acquire(self.config, args)
        self.assertTrue((self.root / 'active.json').exists())
        self.assertIn('enabled = false', self.config_file.read_text())

    def test_zombie_owner_is_an_expired_process(self):
        proc = self.root / 'proc'
        (proc / '22').mkdir(parents=True)
        (proc / 'sys/kernel/random').mkdir(parents=True)
        (proc / 'sys/kernel/random/boot_id').write_text('boot')
        fields = ['Z', '1'] + ['0'] * 17 + ['1234']
        (proc / '22/stat').write_text('22 (worker) ' + ' '.join(fields))
        with self.assertRaises(ProcessLookupError):
            host.owner_identity(22, proc)

    def test_cleanup_retains_output_before_reclaiming_only_its_lease(self):
        scratch = self.root / 'scratch'
        work = scratch / 'run_test'
        (work / 'shared/output').mkdir(parents=True)
        (work / 'shared/output/result.json').write_text('evidence')
        other = scratch / 'run_other'
        other.mkdir()
        config = {'work_roots': [str(scratch)], 'evidence_root': str(self.root / 'evidence')}
        journal = {'work': str(work), 'lease': 'run_test'}
        host.collect_and_remove_work(config, journal)
        self.assertEqual((self.root / 'evidence/run_test/result.json').read_text(), 'evidence')
        self.assertFalse(work.exists())
        self.assertTrue(other.exists())

    def test_cleanup_rejects_a_directory_outside_approved_roots(self):
        work = self.root / 'run_test'
        work.mkdir()
        with self.assertRaisesRegex(ValueError, 'approved scratch'):
            host.collect_and_remove_work({'work_roots': [str(self.root / 'approved')]},
                                         {'work': str(work), 'lease': 'run_test'})
        self.assertTrue(work.exists())


if __name__ == '__main__':
    unittest.main()
