#!/usr/bin/env bash
set -euo pipefail
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
python3 -B - "$repository_root" <<'PY'
import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('assembler', root / 'scripts/assemble-runner-index.py')
a = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)
co = a.co
INDEX = 'application/vnd.oci.image.index.v1+json'
MANIFEST = 'application/vnd.oci.image.manifest.v1+json'
SOURCE, RUNNER = '1' * 40, '2' * 40

class AssemblyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.matrix = co.matrices()
        self.real_run = a.subprocess.run
        self.candidates = {}
        for key, (row, arch) in co.expected_platforms(self.matrix).items():
            candidate = dict(schema=1, type='mesh-llm-runner-image-platform-candidate', image=co.IMAGE,
                environment=row['environment'], backend=co.backend(row), mesh_revision=SOURCE,
                runner_images_revision=RUNNER, platform={'os':'linux','architecture':arch},
                digest=co.digest(('root-'+key).encode()), child_digest=co.digest(key.encode()))
            self.candidates[key] = candidate
            self.save(key)
        self.commands = []
        self.mode = None
        self.row = next(row for row in self.matrix['promotion_matrix']['include'] if row['environment']=='public' and row['backend_id']=='cpu')

    def save(self, key):
        (self.directory / ('candidate-platform-'+key+'.json')).write_text(json.dumps(self.candidates[key]))

    def create(self, command, **kwargs):
        if command[0] != 'docker':
            return self.real_run(command, **kwargs)
        self.commands.append(command)
        self.assertEqual(command[:5], ['docker','buildx','imagetools','create','--tag'])
        self.assertEqual(command[5], co.IMAGE+':candidate-789-2-'+self.row['environment']+'-'+self.row['backend_id'])
        # Registry resolves the actual immutable sources passed to create, not the expected catalog row.
        by_digest = {c['digest']:c for c in self.candidates.values()}
        manifests = []
        for source in command[6:]:
            self.assertTrue(source.startswith(co.IMAGE+'@sha256:'))
            candidate = by_digest[source.split('@')[1]]
            manifests.append(dict(mediaType=MANIFEST, size=123, digest=candidate['child_digest'], platform=copy.deepcopy(candidate['platform'])))
        if self.mode == 'child': manifests[0]['digest'] = 'sha256:'+'f'*64
        if self.mode == 'duplicate': manifests.append(copy.deepcopy(manifests[0]))
        if self.mode == 'platform': manifests[0]['platform']['architecture'] = 's390x'
        if self.mode == 'variant': manifests[-1]['platform']['variant'] = 'v8'
        if self.mode in ('attestation', 'bad-attestation'):
            manifests.append(dict(mediaType=MANIFEST, size=321, digest='sha256:'+'e'*64,
                platform={'os':'unknown','architecture':'unknown'} if self.mode=='attestation' else {'os':'linux','architecture':'amd64'},
                annotations={'vnd.docker.reference.type':'attestation-manifest'}))
        self.raw = co.raw(dict(schemaVersion=2, mediaType=INDEX, manifests=manifests))
        if self.mode == 'duplicate-key': self.raw = self.raw.replace(b'"schemaVersion":2', b'"schemaVersion":2,"schemaVersion":2')
        self.digest = co.digest(self.raw)

    def inspect(self, command):
        self.commands.append(command)
        if command[-1] == '--raw':
            self.assertEqual(command[-2], co.IMAGE+'@'+self.digest)
            return self.raw+b' ' if self.mode=='digest' else self.raw
        return co.raw({'digest':self.digest})

    def assemble(self):
        with patch.object(a.subprocess, 'run', side_effect=self.create), patch.object(co.binder.oci, 'command', side_effect=self.inspect):
            return a.assemble(self.directory, self.row['environment'], self.row['backend_id'], SOURCE, RUNNER,789,2)

    def test_all_catalog_indexes_and_mixed_mapping(self):
        self.assertEqual(len(self.matrix['promotion_matrix']['include']),16)
        for row in self.matrix['promotion_matrix']['include']:
            with self.subTest(row=row['artifact']):
                self.row = row
                result = self.assemble()
                self.assertEqual(result['digest'],self.digest)
                self.assertEqual([c['architecture'] for c in result['children']], sorted(row['architectures'].split(',')))
                if row['backend_id']=='compatibility':
                    self.assertEqual([c['digest'] for c in result['children']], [self.candidates[k]['child_digest'] for k in ('self-hosted-cuda12-amd64','self-hosted-cpu-arm64')])

    def test_mixed_source_catalog_change(self):
        self.row=next(row for row in self.matrix['promotion_matrix']['include'] if row['backend_id']=='compatibility')
        catalog=co.read(co.ROOT/'config/runner-image-families.json')
        for index in catalog['indexes']:
            if index['artifact']==self.row['artifact']:
                for source in index['sources']:
                    if source['architecture']=='amd64': source['backend_id']='cuda13'
        real_read=co.read
        def read(path):
            return catalog if path.name=='runner-image-families.json' else real_read(path)
        with patch.object(co,'read',side_effect=read):
            result=self.assemble()
        self.assertEqual(result['children'][0]['digest'],self.candidates['self-hosted-cuda13-amd64']['child_digest'])
        self.assertEqual(result['children'][1]['digest'],self.candidates['self-hosted-cpu-arm64']['child_digest'])

    def test_wrong_sources_fail_before_registry_mutation(self):
        key='public-cpu-arm64'
        original=copy.deepcopy(self.candidates[key])
        for field,value in [('mesh_revision','3'*40),('runner_images_revision','3'*40),('environment','self-hosted'),('backend',co.backend(next(r for r in self.matrix['family_matrix']['include'] if r['backend_id']=='vulkan'))),('image','ghcr.io/other/image'),('platform',{'os':'linux','architecture':'amd64'})]:
            with self.subTest(field=field):
                self.candidates[key]=copy.deepcopy(original)
                self.candidates[key][field]=value
                self.save(key)
                with self.assertRaises(ValueError): self.assemble()
                self.assertEqual(self.commands,[])

    def test_missing_candidate_before_mutation(self):
        (self.directory/'candidate-platform-public-cpu-arm64.json').unlink()
        with self.assertRaises((ValueError,OSError)): self.assemble()
        self.assertEqual(self.commands,[])

    def test_duplicate_source_or_child_before_mutation(self):
        for field in ('digest','child_digest'):
            with self.subTest(field=field):
                original=self.candidates['public-cpu-arm64'][field]
                self.candidates['public-cpu-arm64'][field]=self.candidates['public-cpu-amd64'][field]
                self.save('public-cpu-arm64')
                with self.assertRaises(ValueError): self.assemble()
                self.assertEqual(self.commands,[])
                self.candidates['public-cpu-arm64'][field]=original

    def test_registry_tampering_rejected_without_output(self):
        output=self.directory/'result.json'
        for mode in ('child','digest','duplicate','platform','bad-attestation','duplicate-key'):
            with self.subTest(mode=mode):
                self.mode=mode
                args=['assemble','--platforms',str(self.directory),'--environment','public','--backend-id','cpu','--mesh-revision',SOURCE,'--runner-images-revision',RUNNER,'--run-id','789','--attempt','2','--output',str(output)]
                with patch.object(sys,'argv',args), patch.object(a.subprocess,'run',side_effect=self.create), patch.object(co.binder.oci,'command',side_effect=self.inspect):
                    with self.assertRaises(ValueError): a.main()
                self.assertFalse(output.exists())

    def test_attestations_and_optional_platform_metadata(self):
        for mode in ('attestation','variant'):
            with self.subTest(mode=mode):
                self.mode=mode
                self.assertEqual(len(self.assemble()['children']),2)

    def test_metadata_limit(self):
        # Exercise the real metadata command wrapper's limit, with no subprocess execution.
        from types import SimpleNamespace
        with patch.object(co.binder.oci.subprocess,'run',return_value=SimpleNamespace(returncode=0,stdout=b' '*(co.binder.oci.MAX_METADATA_BYTES+1),stderr=b'')):
            with self.assertRaisesRegex(ValueError,'16 MiB'): co.binder.oci.command(['docker'])

unittest.main(argv=['index-assembly'],verbosity=2)
PY
