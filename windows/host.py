#!/usr/bin/env python3
"""Journal a reserved host's GPU handoff and recover it independently of the job."""

import argparse
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import time
from pathlib import Path

from vm import gpu_devices, request_guest_cancel

STATE = Path('/var/lib/mesh-windows')
CONFIG = Path('/etc/mesh-windows/host.json')
PCI = Path('/sys/bus/pci/devices')
BOOT_ID = Path('/proc/sys/kernel/random/boot_id')


def command(*args, **kwargs):
    return subprocess.run(list(map(str, args)), check=True, timeout=180,
                          capture_output=True, text=True, **kwargs).stdout


def save(path, value):
    temporary = path.with_suffix('.new')
    with temporary.open('w') as stream:
        json.dump(value, stream, indent=2)
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)
    descriptor = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def digest(path):
    path = Path(path)
    return [hashlib.sha256(path.read_bytes()).hexdigest(), path.stat().st_mtime_ns]


def jy(config, action, *arguments):
    return command('runuser', '-u', config['job_user'], '--', 'env',
                   'HOME=' + config['job_home'], config['jy_binary'], action, *arguments)


def conditional_admission(config, enabled, snapshot, *, check_only=False):
    arguments = ['--enabled', str(enabled).lower(), '--if-config-sha256', snapshot[0],
                 '--if-config-mtime-ns', str(snapshot[1])]
    if check_only:
        arguments.append('--check-only')
    value = json.loads(jy(config, 'admission', *arguments))
    if (set(value) != {'sha256', 'mtime_ns'} or
            not re.fullmatch('[a-f0-9]{64}', value['sha256']) or
            type(value['mtime_ns']) is not int or value['mtime_ns'] < 0):
        raise ValueError('scheduler returned an invalid conditional admission receipt')
    return [value['sha256'], value['mtime_ns']]


def owner_identity(pid, proc=Path('/proc')):
    root = proc / str(pid)
    fields = (root / 'stat').read_text().rsplit(')', 1)[1].split()
    if fields[0] in ('Z', 'X', 'x'):
        raise ProcessLookupError('reservation owner has exited')
    # Start ticks distinguish a surviving owner from a recycled PID.
    return {'pid': pid, 'start': fields[19],
            'boot': (proc / 'sys/kernel/random/boot_id').read_text().strip()}


def owner_alive(owner):
    try:
        return owner_identity(owner['pid']) == owner
    except (OSError, ValueError):
        return False


def verify_reservation(config, args):
    status = jy(config, 'status')
    if 'not connected' in status or '1 slot(s)' not in status:
        raise ValueError('a connected, single-slot scheduler is required')
    owner = Path('/proc') / str(args.owner_pid)
    if owner.stat().st_uid != config['job_uid']:
        raise ValueError('reservation owner must be the enrolled job account')
    environment = dict(item.split(b'=', 1) for item in (owner / 'environ').read_bytes().split(b'\0') if b'=' in item)
    run = environment.get(b'JIANYANG_RUN_ID', b'').decode()
    if run:
        active = re.findall(r'^\s+(run_[a-z0-9]+)\s+·', status, re.MULTILINE)
        if active != [run] or args.lease != run:
            raise ValueError('exclusive native reservation does not match its owner')
    else:
        run = environment.get(b'GITHUB_RUN_ID', b'').decode()
        attempt = environment.get(b'GITHUB_RUN_ATTEMPT', b'').decode()
        job = environment.get(b'GITHUB_JOB', b'').decode()
        expected = f'github-{run}-{attempt}-{job}-{config["backend"]}'
        if not run.isdigit() or args.lease != expected or 'no jobs running' not in status:
            raise ValueError('GitHub reservation identity does not match its owner')
        # Persistent native listeners are admitted by the scheduler's job hook.
        # Refuse a host with multiple workers or without its accepted-job marker.
        workers = [p for p in Path('/proc').glob('[0-9]*')
                   if (p / 'comm').exists() and (p / 'comm').read_text().strip() == 'Runner.Worker']
        if len(workers) != 1 or not Path(config['github_busy_marker']).is_file():
            raise ValueError('one accepted native GitHub worker is required')
        parent = args.owner_pid
        ancestors = set()
        while parent > 1 and parent not in ancestors:
            ancestors.add(parent)
            parent = int((Path('/proc') / str(parent) / 'stat').read_text().rsplit(')', 1)[1].split()[1])
        if int(workers[0].name) not in ancestors:
            raise ValueError('reservation owner is outside the accepted GitHub worker')
    return owner_identity(args.owner_pid)


def set_driver(bdf, target):
    device = PCI / bdf
    current = device / 'driver'
    if target is None:
        if current.is_symlink():
            (current / 'unbind').write_text(bdf)
        (device / 'driver_override').write_text('\n')
        if current.is_symlink():
            raise RuntimeError(f'{bdf}: failed to restore an unbound function')
        return
    if current.is_symlink() and current.resolve().name == target:
        return
    (device / 'driver_override').write_text(target)
    if current.is_symlink():
        (current / 'unbind').write_text(bdf)
    Path('/sys/bus/pci/drivers_probe').write_text(bdf)
    if not current.is_symlink() or current.resolve().name != target:
        raise RuntimeError(f'{bdf}: failed to bind {target}')


def gpu_paths(devices):
    paths = set()
    for bdf in devices:
        for node in (PCI / bdf / 'drm').glob('*'):
            paths.add('/dev/dri/' + node.name)
    for device in devices:
        info = Path('/proc/driver/nvidia/gpus') / device / 'information'
        if info.exists():
            minor = re.search(r'Device Minor:\s*(\d+)', info.read_text())
            if minor:
                paths.add('/dev/nvidia' + minor[1])
    return paths


def refuse_open_devices(paths):
    for process in Path('/proc').glob('[0-9]*'):
        for fd in (process / 'fd').glob('*'):
            try:
                if os.readlink(fd) in paths:
                    raise ValueError(f'GPU is still used by process {process.name}')
            except (FileNotFoundError, PermissionError):
                pass


def native_probe(config):
    if config['backend'] == 'cuda':
        if 'GPU ' not in command('nvidia-smi', '-L'):
            raise RuntimeError('native NVIDIA discovery failed')
    else:
        device = int((PCI / config['gpu'] / 'device').read_text().strip(), 16)
        nodes = Path('/sys/class/kfd/kfd/topology/nodes')
        matches = []
        for node in nodes.glob('*'):
            properties = dict(line.split() for line in (node / 'properties').read_text().splitlines() if len(line.split()) == 2)
            if int(properties.get('device_id', '0')) == device and int((node / 'gpu_id').read_text()) > 0:
                matches.append(node)
        if len(matches) != 1:
            raise RuntimeError('native AMD KFD discovery failed')


def acquire(config, args):
    implementation = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    if getattr(args, 'expected_host_sha256', None) != implementation:
        raise ValueError('installed host helper does not match the admitted recipe')
    if (STATE / 'active.json').exists():
        raise ValueError('host has an unreconciled GPU journal')
    before_pause = digest(config['jy_config'])
    settings = Path(config['jy_config']).read_text()
    if digest(config['jy_config']) != before_pause:
        raise ValueError('scheduler changed during admission; retry with its current settings')
    if not re.search(r'^enabled\s*=\s*true\s*$', settings, re.MULTILINE) or re.search(r'^drain\s*=\s*true\s*$', settings, re.MULTILINE):
        raise ValueError('scheduler must be enabled and not draining')
    owner = verify_reservation(config, args)
    work = None
    if args.work:
        work = args.work.resolve()
        roots = [Path(path).resolve() for path in config.get('work_roots', [])]
        if work.name != args.lease or work.parent not in roots or work.exists():
            raise ValueError('VM work must be a fresh lease directory under an approved scratch root')
    group, devices = gpu_devices(config['backend'], args.gpu, require_vfio=False)
    native_probe(config)
    # Probe both CLI and daemon support before creating a journal or touching PCI.
    conditional_admission(config, False, before_pause, check_only=True)
    bindings = {bdf: (PCI / bdf / 'driver').resolve().name
                if (PCI / bdf / 'driver').is_symlink() else None for bdf in devices}
    if any(driver == 'vfio-pci' for driver in bindings.values()):
        raise ValueError('GPU was already assigned before acquisition')
    journal = {'schema': 1, 'lease': args.lease, 'gpu': args.gpu, 'group': group,
               'owner': owner, 'deadline': time.time() + 7200, 'bindings': bindings,
               'services': [], 'consoles': [], 'state': 'acquiring',
               'phase': 'before-pause', 'config_before_pause': before_pause}
    if work:
        journal['work'] = str(work)
    save(STATE / 'active.json', journal)
    # Persist scheduler quarantine before the first host/device mutation. The
    # paused setting survives reboot; a job trap is not the recovery mechanism.
    journal['paused_config'] = conditional_admission(config, False, before_pause)
    journal['phase'] = 'paused'
    save(STATE / 'active.json', journal)
    command('modprobe', 'vfio-pci')
    for service in ['display-manager.service', 'nvidia-persistenced.service']:
        result = subprocess.run(['systemctl', 'is-active', '--quiet', service], check=False)
        if result.returncode == 0:
            journal['services'].append(service)
            save(STATE / 'active.json', journal)
            command('systemctl', 'stop', service)
    refuse_open_devices(gpu_paths(devices))
    if config['backend'] == 'rocm':
        for console in Path('/sys/class/vtconsole').glob('vtcon*'):
            if 'frame buffer' in (console / 'name').read_text() and (console / 'bind').read_text().strip() == '1':
                journal['consoles'].append(str(console / 'bind'))
                save(STATE / 'active.json', journal)
                (console / 'bind').write_text('0')
    for bdf in devices:
        set_driver(bdf, 'vfio-pci')
    journal['state'] = 'assigned'
    save(STATE / 'active.json', journal)
    return journal


def verify_launch_owner(config, pid, owner, proc=Path('/proc')):
    caller = proc / str(pid)
    if caller.stat().st_uid != config['job_uid']:
        raise ValueError('container caller must be the enrolled job account')
    parent = pid
    ancestors = set()
    while parent > 1 and parent not in ancestors:
        ancestors.add(parent)
        parent = int((proc / str(parent) / 'stat').read_text().rsplit(')', 1)[1].split()[1])
    if owner['pid'] not in ancestors:
        raise ValueError('container caller is outside the lease owner process tree')


def launch(config, args, journal):
    if (journal['state'] != 'assigned' or time.time() >= journal['deadline'] or
            not owner_alive(journal['owner'])):
        raise ValueError('Windows lease is no longer active; refusing container creation')
    verify_launch_owner(config, args.owner_pid, journal['owner'])
    work = Path(journal['work'])
    spec = args.launch_spec
    if not spec or spec.is_symlink() or spec.resolve() != work / 'launch.json':
        raise ValueError('container launch spec must belong to the current lease workspace')
    value = json.loads(spec.read_text())
    name, arguments = value['name'], value['arguments']
    if (not re.fullmatch('mesh-windows-[a-f0-9]{32}', name) or
            not isinstance(arguments, list) or not all(isinstance(a, str) for a in arguments) or
            'mesh.windows.lease=' + journal['lease'] not in arguments):
        raise ValueError('container launch does not identify its current lease')
    _, devices = gpu_devices(config['backend'], config['gpu'])
    if set(devices) != set(journal['bindings']):
        raise ValueError('assigned PCI functions changed before container creation')
    # main holds the recovery lock through BOTH operations. Recovery either sees
    # this created container or revokes the lease before a late caller can start it.
    docker = ['runuser', '-u', config['job_user'], '--', 'env',
              'HOME=' + config['job_home'], 'docker']
    created = False
    try:
        command(*docker, 'create', '--name', name, *arguments)
        created = True
        command(*docker, 'start', name)
    except Exception:
        if created:
            command(*docker, 'rm', '--force', name)
        raise


def collect_and_remove_work(config, journal):
    if 'work' not in journal:
        return
    work = Path(journal['work'])
    roots = [Path(path).resolve() for path in config['work_roots']]
    if work.is_symlink() or work.resolve() != work or work.parent not in roots or work.name != journal['lease']:
        raise ValueError('refusing cleanup outside this lease\'s approved scratch directory')
    if not work.exists():
        return
    output = work / 'shared/output'
    if output.exists():
        if output.is_symlink() or any(p.is_symlink() for p in output.rglob('*')):
            raise ValueError('refusing symlinks in retained guest evidence')
        archive = Path(config['evidence_root']) / journal['lease']
        if archive.is_symlink():
            raise ValueError('refusing a symlink as the evidence archive')
        shutil.copytree(output, archive, dirs_exist_ok=True)
        journal['retained_evidence'] = str(archive)
    shutil.rmtree(work)


def bindings_restored(journal):
    return all((not (PCI / bdf / 'driver').is_symlink() if driver is None else
               (PCI / bdf / 'driver').is_symlink() and
               (PCI / bdf / 'driver').resolve().name == driver)
               for bdf, driver in journal['bindings'].items())


def verify_amd_release(config, journal):
    if config['backend'] != 'rocm' or 'work' not in journal:
        return
    work = Path(journal['work'])
    if not (work / 'shared/input/driver.json').exists():
        return
    boot = BOOT_ID.read_text().strip()
    previous_boot = journal.get('owner', {}).get('boot')
    if previous_boot and previous_boot != boot:
        # A host restart can reconcile a quarantined device. Admit it only
        # after its original bindings and native discovery already work.
        if not bindings_restored(journal):
            raise RuntimeError('host restarted without original AMD bindings; retain quarantine')
        native_probe(config)
        return True
    # An initialized Windows APU must unload before Linux can reclaim it.
    # Blind rebinding can wedge the host; absent proof retains VFIO quarantine.
    path = work / 'shared/output/gpu-release.json'
    value = json.loads(path.read_text(encoding='utf-8-sig')) if path.is_file() else {}
    result = work / 'shared/output/result.json'
    finished = json.loads(result.read_text(encoding='utf-8-sig')) if result.is_file() else {}
    device = (PCI / config['gpu'] / 'device').read_text().strip()[2:].upper()
    identity = 'PCI\\VEN_1002&DEV_' + device
    if (not isinstance(finished, dict) or finished.get('schema') != 1 or
            type(finished.get('exit_code')) is not int or
            not isinstance(value, dict) or value.get('ConfigManagerErrorCode') != 22 or
            not str(value.get('PNPDeviceID', '')).startswith(identity)):
        raise RuntimeError('AMD Windows guest did not confirm device release; retain VFIO quarantine')
    return True


def restore(config, journal):
    if (journal.get('phase') == 'before-pause' and 'paused_config' not in journal and
            digest(config['jy_config']) == journal.get('config_before_pause')):
        if not bindings_restored(journal):
            raise RuntimeError('interrupted acquisition changed PCI before its pause receipt')
        native_probe(config)
        collect_and_remove_work(config, journal)
        journal['state'] = 'restored'
        save(STATE / 'last.json', journal)
        (STATE / 'active.json').unlink()
        return journal
    unchanged = digest(config['jy_config']) == journal.get('paused_config')
    if not unchanged:
        jy(config, 'off')
    ids = command('docker', 'ps', '-aq', '--filter', 'label=mesh.windows.lease=' + journal['lease']).split()
    if ids and config['backend'] == 'rocm' and journal.get('work'):
        request_guest_cancel(Path(journal['work']) / 'shared')
    for container in ids:
        command('docker', 'stop', '--time', '120', container)
        command('docker', 'rm', '--force', container)
    if verify_amd_release(config, journal):
        boot = BOOT_ID.read_text().strip()
        if journal.get('native_rebind_boot') == boot and not bindings_restored(journal):
            raise RuntimeError('AMD native rebind already failed on this boot; retain quarantine without retry')
        # Persist before touching a driver. A timer retry must not repeat a
        # failed Windows-to-Linux transition, even if its process was killed.
        journal['native_rebind_boot'] = boot
        save(STATE / 'active.json', journal)
    for bdf, driver in reversed(list(journal['bindings'].items())):
        if driver is not None:
            command('modprobe', driver)
        set_driver(bdf, driver)
        (PCI / bdf / 'driver_override').write_text('\n')
    native_probe(config)
    for path in journal['consoles']:
        Path(path).write_text('1')
    for service in journal['services']:
        command('systemctl', 'start', service)
    # An operator's intervening change wins. Preserve quarantine instead of
    # implicitly clearing a newly requested pause/drain or changing quotas.
    if not unchanged or digest(config['jy_config']) != journal.get('paused_config'):
        raise RuntimeError('scheduler configuration changed; operator reconciliation required')
    collect_and_remove_work(config, journal)
    journal['state'] = 'restored'
    save(STATE / 'last.json', journal)
    conditional_admission(config, True, journal['paused_config'])
    (STATE / 'active.json').unlink()
    return journal


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['describe', 'acquire', 'launch', 'release', 'recover'])
    parser.add_argument('--lease')
    parser.add_argument('--gpu')
    parser.add_argument('--journal', type=Path)
    parser.add_argument('--owner-pid', type=int)
    parser.add_argument('--backend', choices=['cuda', 'rocm'])
    parser.add_argument('--work', type=Path)
    parser.add_argument('--firmware', action='store_true')
    parser.add_argument('--launch-spec', type=Path)
    parser.add_argument('--expected-host-sha256')
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise ValueError('host lifecycle operations require the installed root helper')
    config = json.loads(CONFIG.read_text())
    if CONFIG.stat().st_uid != 0 or CONFIG.stat().st_mode & 0o022:
        raise ValueError('host configuration must be root-owned and not writable by jobs')
    if args.action == 'describe':
        if args.backend != config['backend']:
            raise ValueError('backend does not match the installed host configuration')
        print(json.dumps(config.get('firmware', {})) if args.firmware else config['gpu'])
        return
    STATE.mkdir(mode=0o700, exist_ok=True)
    with (STATE / 'lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if args.action == 'recover':
            if not (STATE / 'active.json').exists():
                return
            journal = json.loads((STATE / 'active.json').read_text())
            if owner_alive(journal['owner']) and time.time() < journal['deadline']:
                return
        else:
            if not args.lease or args.gpu != config['gpu'] or not args.owner_pid:
                raise ValueError('lease, approved GPU and owner PID are required')
            if args.action == 'acquire':
                journal = acquire(config, args)
                if args.journal:
                    save(args.journal, journal)
                return
            if not (STATE / 'active.json').exists():
                if args.action == 'launch':
                    raise ValueError('Windows lease was retired before container creation')
                return
            journal = json.loads((STATE / 'active.json').read_text())
            if journal['lease'] != args.lease:
                raise ValueError('release cannot change another reservation')
            if args.action == 'launch':
                launch(config, args, journal)
                return
        try:
            journal['state'] = 'releasing'
            save(STATE / 'active.json', journal)
            result = restore(config, journal)
        except Exception as error:
            journal['state'] = 'quarantined'
            journal['error'] = str(error)
            save(STATE / 'active.json', journal)
            raise
        if args.journal:
            save(args.journal, result)


if __name__ == '__main__':
    main()
