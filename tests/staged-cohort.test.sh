#!/usr/bin/env bash
set -euo pipefail
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
python3 -B - "$repository_root" <<'PY'
import base64
import copy
from datetime import datetime, timezone
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

root = Path(sys.argv[1])
def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded
co = module('cohort', root / 'scripts/runner-cohort.py')
f = module('fixtures', root / 'tests/fixtures/runner_identity.py')

class CohortTests(f.IdentityFixtures):
    def setUp(self):
        super().setUp()
        # Bind using actual checked-in policy, including the full Python lock.
        self.expected = root / 'config'
        self.pins, self.policy = co.binder.identity.read_policy(self.expected)
        self.matrix = co.matrices()
        self.catalog = co.read(root / 'config/runner-image-families.json')
        self.cohort = {'schema':1, 'type':'mesh-llm-runner-staged-cohort', 'image':co.IMAGE,
            'catalog_sha256': co.digest(co.raw(self.catalog)),
            'origin': {'repository':co.REPOSITORY, 'repository_id':123, 'workflow_id':456,
                'workflow_path':co.WORKFLOW, 'run_id':789, 'run_attempt':2, 'event':'push',
                'mesh_revision':f.SOURCE, 'runner_images_revision':f.RUNNER, 'timestamp':'20260907235959'},
            'platforms':{}, 'candidates':{}}
        for key, (row, arch) in co.expected_platforms(self.matrix).items():
            evidence = self.fixture(row['backend_name'], arch)
            candidate = evidence['candidate']
            candidate.update(image=co.IMAGE, environment=row['environment'], backend=co.backend(row))
            runtime = evidence['runtime']
            runtime['family'] = {'environment':row['environment'], 'backend':row['backend_name'],
                                **{k:candidate['backend'][k] for k in ('cuda_series','rocm_version')}}
            runtime['verification']['verifier_revision'] = f.RUNNER
            # Give every platform distinct OCI bytes, as a real family would have.
            manifest = json.loads(evidence['manifest_raw'])
            manifest['annotations'] = {'fixture':key}
            self.update_manifest(evidence, manifest)
            receipt = co.binder.bind(**evidence, expected_directory=self.expected, verifier_revision=f.RUNNER)
            self.cohort['platforms'][key] = {'candidate': candidate, 'receipt':receipt,
                'index_base64':base64.b64encode(evidence['root_raw']).decode(),
                'manifest_base64':base64.b64encode(evidence['manifest_raw']).decode()}
        mixed = {r['artifact']:r['sources'] for r in self.catalog['indexes']}
        self.registry = {}
        for row in self.matrix['promotion_matrix']['include']:
            sources = mixed.get(row['artifact'], [{'environment':row['environment'],'backend_id':row['backend_id'],'architecture':arch}
                                                  for arch in row['architectures'].split(',')])
            children = sorted([{'os':'linux','architecture':s['architecture'],
                'digest':self.cohort['platforms'][co.platform_key(**s)]['candidate']['child_digest']} for s in sources], key=lambda c:c['architecture'])
            index = {'schemaVersion':2,'mediaType':f.INDEX, 'manifests':[{'digest':c['digest'],'size':123,'mediaType':f.MANIFEST,
                'platform':{'os':'linux','architecture':c['architecture']}} for c in children]}
            value = {'schema':1,'type':'mesh-llm-runner-image-candidate','image':co.IMAGE,
                     'environment':row['environment'],'backend':co.backend(row),'mesh_revision':f.SOURCE,
                     'runner_images_revision':f.RUNNER,'digest':co.digest(co.raw(index)),'children':children}
            self.cohort['candidates'][row['artifact']] = value
            self.registry[co.IMAGE+'@'+value['digest']] = index
        self.run = {'id':789,'run_attempt':2,'workflow_id':456,'path':co.WORKFLOW,'head_branch':'main',
                    'head_sha':f.RUNNER,'repository':{'full_name':co.REPOSITORY,'id':123},
                    'head_repository':{'full_name':co.REPOSITORY,'id':123},'event':'push',
                    'status':'completed','conclusion':'success'}
        self.workflow = {'id':456,'path':co.WORKFLOW}
        self.artifact = {'id':111,'name':'staged-cohort-789-2','expired':False,'expires_at':'2099-09-08T00:00:00Z',
            'workflow_run':{'id':789,'repository_id':123,'head_repository_id':123,'head_branch':'main','head_sha':f.RUNNER}}
        self.archive = self.zip()
        self.artifact.update(size_in_bytes=len(self.archive),digest=co.digest(self.archive))

    def zip(self, filename='staged-cohort.json', mode=stat.S_IFREG|0o644, extra=False):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer,'w') as archive:
            entry = zipfile.ZipInfo(filename)
            entry.external_attr = mode << 16
            archive.writestr(entry,co.raw(self.cohort))
            if extra: archive.writestr('extra.json','{}')
        return buffer.getvalue()

    def test_complete_catalog_and_mixed_sources(self):
        self.assertEqual(co.validate(self.cohort),self.matrix)
        self.assertEqual(len(self.cohort['platforms']),23)
        self.assertEqual(len(self.cohort['candidates']),16)
        mixed=self.cohort['candidates']['candidate-index-self-hosted-compatibility']['children']
        self.assertEqual(mixed[0]['digest'],self.cohort['platforms']['self-hosted-cuda12-amd64']['candidate']['child_digest'])
        self.assertEqual(mixed[1]['digest'],self.cohort['platforms']['self-hosted-cpu-arm64']['candidate']['child_digest'])

    def test_reject_missing_extra_duplicate_or_stale_data(self):
        mutations = [lambda c:c['platforms'].pop(next(iter(c['platforms']))),
            lambda c:c['candidates'].pop(next(iter(c['candidates']))),
            lambda c:c['platforms'].update(extra=next(iter(c['platforms'].values()))),
            lambda c:c.update(catalog_sha256='sha256:'+'0'*64),
            lambda c:c['origin'].update(mesh_revision='a'*40),
            lambda c:c['origin'].update(run_attempt=True),
            lambda c:c['origin'].update(timestamp='20269999999999'),
            lambda c:c['candidates']['candidate-index-self-hosted-compatibility']['children'][0].update(digest='sha256:'+'0'*64)]
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                value=copy.deepcopy(self.cohort);mutation(value)
                with self.assertRaises(ValueError):co.validate(value)
        with self.assertRaises(ValueError):co.decode(b'{"a":1,"a":2}')

    def test_reject_tampered_receipt_or_raw_metadata(self):
        for mutation in [lambda e:e['receipt']['runtime']['tools']['just'].update(version='0.0.1'),
                         lambda e:e.update(index_base64=base64.b64encode(b'{}').decode()),
                         lambda e:e['receipt']['oci']['manifest'].update(digest='sha256:'+'0'*64),
                         lambda e:e['receipt']['runtime']['verification'].update(verifier_revision='0'*40)]:
            value=copy.deepcopy(self.cohort);mutation(value['platforms']['public-cpu-amd64'])
            with self.assertRaises(ValueError):co.validate(value)

    def test_successful_exact_attempt(self):
        co.validate_run(self.run,self.workflow,789,2)
        co.validate_artifact(self.artifact,self.run,datetime.now(timezone.utc))
        co.match_origin(self.cohort,self.run)
        self.assertEqual(co.unpack_archive(self.archive,self.artifact),self.cohort)

    def test_reject_untrusted_runs_and_other_attempts(self):
        for changes in [{'run_attempt':3},{'id':790},{'head_branch':'topic'},{'path':'other.yml'},
                        {'workflow_id':777},{'event':'pull_request'},{'status':'in_progress'},
                        {'conclusion':'failure'},{'conclusion':'cancelled'},
                        {'repository':{'full_name':'fork/repo','id':123}},
                        {'head_repository':{'full_name':co.REPOSITORY,'id':456}}]:
            value={**self.run,**changes}
            with self.subTest(changes=changes),self.assertRaises(ValueError):co.validate_run(value,self.workflow,789,2)
        with self.assertRaises(ValueError):co.validate_run(self.run,{'id':456,'path':'other.yml'},789,2)

    def test_same_running_attempt_exception_only_for_seal(self):
        running={**self.run,'status':'in_progress','conclusion':None}
        co.validate_run(running,self.workflow,789,2,allow_running=True)
        with self.assertRaises(ValueError):co.validate_run(running,self.workflow,789,2)
        with self.assertRaises(ValueError):co.validate_run(self.run,self.workflow,789,2,allow_running=True)
        with self.assertRaises(ValueError):co.match_origin(self.cohort,{**self.run,'run_attempt':3})

    def test_reject_expired_wrong_source_and_missing_digest_artifacts(self):
        for changes in [{'expired':True},{'expires_at':'2000-01-01T00:00:00Z'}, {'name':'staged-cohort-789-1'},
                        {'digest':None},{'size_in_bytes':co.MAX_BYTES+1},
                        {'workflow_run':{**self.artifact['workflow_run'],'head_sha':'0'*40}},
                        {'workflow_run':{**self.artifact['workflow_run'],'head_repository_id':999}}]:
            with self.subTest(changes=changes),self.assertRaises(ValueError):
                co.validate_artifact({**self.artifact,**changes},self.run,datetime.now(timezone.utc))

    def test_reject_unsafe_or_tampered_archives(self):
        with self.assertRaises(ValueError):co.unpack_archive(self.archive+b' ',self.artifact)
        for filename,mode,extra in [('../staged-cohort.json',stat.S_IFREG,False),
                                   ('staged-cohort.json',stat.S_IFLNK,False),
                                   ('staged-cohort.json',stat.S_IFREG,True)]:
            archive=self.zip(filename,mode,extra)
            artifact={**self.artifact,'size_in_bytes':len(archive),'digest':co.digest(archive)}
            with self.assertRaises(ValueError):co.unpack_archive(archive,artifact)

    def test_fetch_uses_exact_attempt_and_immutable_artifact_id(self):
        endpoints=[]
        def api(endpoint):
            endpoints.append(endpoint)
            if '/attempts/2' in endpoint:return self.run
            if '/workflows/' in endpoint:return self.workflow
            if '/artifacts?' in endpoint:return {'artifacts':[self.artifact]}
            if endpoint.endswith('/artifacts/111'):return self.artifact
            raise AssertionError(endpoint)
        original_run=subprocess.run
        def download(command,**kwargs):
            if command[0]=='gh':
                self.assertTrue(command[-1].endswith('/artifacts/111/zip'))
                kwargs['stdout'].write(self.archive)
                return subprocess.CompletedProcess(command,0)
            return original_run(command,**kwargs)
        with patch.object(co,'gh_json',side_effect=api),patch.object(co.subprocess,'run',side_effect=download):
            self.assertEqual(co.fetch(789,2),self.cohort)
        self.assertTrue(endpoints[0].endswith('/runs/789/attempts/2'))
        self.assertTrue(any('/artifacts/111' in e for e in endpoints))
        def duplicate(endpoint):
            if '/artifacts?' in endpoint:return {'artifacts':[self.artifact,self.artifact]}
            return api(endpoint)
        with patch.object(co,'gh_json',side_effect=duplicate),self.assertRaises(ValueError):co.fetch(789,2)

    def test_export_does_not_execute_cohort_data(self):
        destination=self.root/'export'
        co.export(self.cohort,destination)
        self.assertEqual(len(list(destination.glob('candidate-index-*.json'))),16)
        self.assertEqual(co.read(destination/'origin.json'),self.cohort['origin'])
        with self.assertRaises(FileExistsError):co.export(self.cohort,destination)

    def test_seal_checks_actual_current_attempt(self):
        running={**self.run,'status':'in_progress','conclusion':None}
        def api(endpoint):return self.workflow if '/workflows/' in endpoint else running
        directory=self.root/'artifacts';directory.mkdir()
        for name,value in self.cohort['candidates'].items():
            folder=directory/(name+'-2');folder.mkdir();(folder/(name+'.json')).write_bytes(co.raw(value))
        for key,entry in self.cohort['platforms'].items():
            name='candidate-platform-'+key;folder=directory/(name+'-2');folder.mkdir();(folder/(name+'.json')).write_bytes(co.raw(entry['candidate']))
            folder=directory/('runner-identity-'+key+'-2');folder.mkdir()
            (folder/'identity.json').write_bytes(co.raw(entry['receipt']))
            (folder/'index.json').write_bytes(base64.b64decode(entry['index_base64']))
            (folder/'manifest.json').write_bytes(base64.b64decode(entry['manifest_base64']))
        environment={'GITHUB_RUN_ID':'789','GITHUB_RUN_ATTEMPT':'2','GITHUB_SHA':f.RUNNER,
                     'GITHUB_WORKFLOW_REF':f'{co.REPOSITORY}/{co.WORKFLOW}@refs/heads/main'}
        with patch.object(co,'gh_json',side_effect=api),patch.dict(os.environ,environment):
            self.assertEqual(co.seal(directory,789,2,f.SOURCE,'20260907235959'),self.cohort)
            with patch.dict(os.environ,{'GITHUB_RUN_ATTEMPT':'1'}),self.assertRaises(ValueError):
                co.seal(directory,789,2,f.SOURCE,'20260907235959')

    def publish(self, output, fail_tag=''):
        cohort=self.root/'cohort.json';cohort.write_bytes(co.raw(self.cohort))
        state=self.root/'registry.json'
        if not state.exists():state.write_bytes(co.raw({'image':co.IMAGE,'indexes':self.registry,'tags':{}}))
        environment={**os.environ,'DOCKER_BIN':str(root/'tests/fixtures/cohort-registry.py'),
            'COHORT_REGISTRY_STATE':str(state),'COHORT_REGISTRY_LOG':str(self.root/'registry.log'),
            'COHORT_FAIL_TAG':fail_tag}
        result=subprocess.run(['bash',str(root/'scripts/publish-runner-cohort.sh'),str(cohort),str(output)],
                              text=True,capture_output=True,env=environment)
        return result,environment

    def test_publication_reuses_all_digests_and_snapshots_before_latest(self):
        output=self.root/'publication'
        result,environment=self.publish(output)
        self.assertEqual(result.returncode,0,result.stderr)
        state=co.read(self.root/'registry.json')
        self.assertFalse(any(tag.endswith('-latest') for tag in state['tags']))
        snapshot=co.read(output/'latest-cohort.json')
        self.assertEqual(len(snapshot['entries']),17)
        self.assertTrue(all(entry['previous_digest'] is None for entry in snapshot['entries']))
        result=subprocess.run(['bash',str(root/'scripts/reconcile-image-cohort.sh'),str(output/'latest-cohort.json'),'target'],
                              text=True,capture_output=True,env=environment)
        self.assertEqual(result.returncode,0,result.stderr)
        state=co.read(self.root/'registry.json')
        for entry in snapshot['entries']:
            self.assertEqual(state['tags'][entry['tag']],entry['target_digest'])
        calls=[json.loads(line) for line in (self.root/'registry.log').read_text().splitlines()]
        self.assertTrue(all(call[:2]==['buildx','imagetools'] for call in calls))
        self.assertTrue(all('@sha256:' in call[-1] for call in calls if call[2]=='create'))
        # Retrying the original cohort retains original versioned tag identities.
        retry=self.root/'retry';result,_=self.publish(retry)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(co.read(retry/'origin.json'),self.cohort['origin'])
        self.assertTrue(all(e['previous_digest']==e['target_digest'] for e in co.read(retry/'latest-cohort.json')['entries']))

    def test_late_versioned_failure_cannot_write_latest_or_snapshot(self):
        output=self.root/'publication'
        result,_=self.publish(output,':self-hosted-2026')
        self.assertNotEqual(result.returncode,0)
        state=co.read(self.root/'registry.json')
        self.assertTrue(state['tags'])
        self.assertFalse(any(tag.endswith('-latest') for tag in state['tags']))
        self.assertFalse((output/'latest-cohort.json').exists())

    def test_invalid_cohort_never_contacts_registry(self):
        self.cohort['platforms'].pop('public-cpu-amd64')
        result,_=self.publish(self.root/'invalid')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse((self.root/'registry.log').exists())

    def test_publication_workflow_lock_and_no_build_dispatch(self):
        workflow=(root/'.github/workflows/build-and-push.yml').read_text()
        publisher=(root/'.github/workflows/publish-cohort.yml').read_text()
        publish=workflow.split('  publish_cohort:\n')[1]
        self.assertIn('    concurrency:\n      group: runner-image-publication\n      cancel-in-progress: false\n      queue: max\n',publish)
        self.assertEqual(workflow.count('queue:'),1)
        self.assertIn("if: github.event_name != 'workflow_dispatch' || inputs.operation != 'promote'",workflow.split('  prepare:\n')[1].split('    steps:')[0])
        admit=workflow.split('  admit_cohort:\n')[1].split('  publish_cohort:\n')[0]
        for text in [admit,publisher]:
            for forbidden in ['depot build','build-push-action','prepare-build-context','MESH_REF','ref: ${{']:
                self.assertNotIn(forbidden,text)
        self.assertNotIn('attest-build-provenance',publisher)
        self.assertLess(publisher.index('Retain latest reconciliation'),publisher.index('Reconcile the complete latest'))
        self.assertIn('artifact-ids: ${{ inputs.artifact_id }}',publisher)
        self.assertIn('needs: [prepare, stage_families, assemble_self_hosted_compatibility]',workflow.split('  seal_cohort:\n')[1])

unittest.main(argv=['staged-cohort'],verbosity=1)
PY
