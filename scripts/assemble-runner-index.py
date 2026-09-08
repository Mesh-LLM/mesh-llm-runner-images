#!/usr/bin/env python3
"""Assemble one catalog index from verified immutable platform candidates."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('cohort', Path(__file__).with_name('runner-cohort.py'))
co = importlib.util.module_from_spec(spec)
spec.loader.exec_module(co)


def assemble(directory, environment, backend_id, mesh_revision, runner_images_revision, run_id, attempt):
    co.require(type(run_id) is int and run_id > 0 and type(attempt) is int and attempt > 0, 'invalid staging run/attempt')
    co.require(co.SHA.fullmatch(mesh_revision) and co.SHA.fullmatch(runner_images_revision), 'invalid source revisions')
    matrix = co.matrices()
    catalog = co.read(co.ROOT / 'config/runner-image-families.json')
    rows = [row for row in matrix['promotion_matrix']['include'] if row['environment'] == environment and row['backend_id'] == backend_id]
    co.require(len(rows) == 1, 'index is not uniquely selected from catalog')
    row = rows[0]
    expected = co.expected_platforms(matrix)
    sources, children = [], []
    for source in co.index_sources(row, catalog):
        key = co.platform_key(**source)
        family, architecture = expected[key]
        candidate = co.read(directory / f'candidate-platform-{key}.json')
        co.binder.validate_candidate(candidate)
        co.require(candidate['image'] == co.IMAGE and candidate['environment'] == family['environment']
                   and candidate['backend'] == co.backend(family)
                   and candidate['platform'] == {'os':'linux','architecture':architecture}
                   and candidate['mesh_revision'] == mesh_revision
                   and candidate['runner_images_revision'] == runner_images_revision, 'platform source differs from catalog/expected revisions')
        sources.append(co.IMAGE + '@' + candidate['digest'])
        children.append({'os':'linux','architecture':architecture,'digest':candidate['child_digest']})
    children.sort(key=lambda child: child['architecture'])
    co.require(len(set(sources)) == len(sources) and len({c['digest'] for c in children}) == len(children), 'duplicate platform source/child digest')
    docker = os.environ.get('DOCKER_BIN', 'docker')
    candidate_tag = f'{co.IMAGE}:candidate-{run_id}-{attempt}-{environment}-{backend_id}'
    subprocess.run([docker, 'buildx', 'imagetools', 'create', '--tag', candidate_tag, *sources], check=True)
    oci = co.binder.oci
    result = co.decode(oci.command([docker, 'buildx', 'imagetools', 'inspect', candidate_tag, '--format', '{{json .Manifest}}']))
    co.require(isinstance(result, dict), 'invalid registry descriptor')
    digest = result.get('digest')
    co.require(isinstance(digest, str) and co.DIGEST.fullmatch(digest), 'registry did not resolve an immutable index digest')
    raw = oci.command([docker, 'buildx', 'imagetools', 'inspect', co.IMAGE + '@' + digest, '--raw'])
    index = co.decode(raw)
    co.require(isinstance(index, dict), 'invalid registry index')
    oci.decode(raw, {'digest':digest, 'size':len(raw), 'mediaType':index.get('mediaType')})
    co.require(index.get('schemaVersion') == 2 and index.get('mediaType') in oci.INDEX_TYPES
               and not index.get('artifactType') and not index.get('subject')
               and isinstance(index.get('manifests'), list), 'registry result is not a runnable image index')
    actual = []
    for entry in index['manifests']:
        oci.metadata_descriptor(entry, oci.MANIFEST_TYPES)
        co.require(isinstance(entry.get('annotations', {}), dict), 'invalid index annotations')
        platform = entry.get('platform', {})
        co.require(isinstance(platform, dict), 'invalid child platform')
        platform = {key: platform.get(key) for key in ('os', 'architecture')}
        if platform == {'os':'unknown','architecture':'unknown'} and entry.get('annotations', {}).get('vnd.docker.reference.type') == 'attestation-manifest':
            continue
        co.require(entry.get('annotations', {}).get('vnd.docker.reference.type') != 'attestation-manifest', 'attestation is not a runnable child')
        co.require(platform in ({'os':'linux','architecture':'amd64'}, {'os':'linux','architecture':'arm64'}), 'unexpected child platform')
        actual.append({**platform,'digest':entry['digest']})
    co.require(sorted(actual, key=lambda child:child['architecture']) == children, 'assembled registry children differ from verified candidates')
    descriptor = {'schema':1,'type':'mesh-llm-runner-image-candidate','image':co.IMAGE,'environment':environment,
                  'backend':co.backend(row),'mesh_revision':mesh_revision,'runner_images_revision':runner_images_revision,
                  'digest':digest,'children':children}
    co.validate_index(descriptor, row, descriptor, children)
    return descriptor


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platforms',type=Path,required=True)
    for name in ('environment','backend-id','mesh-revision','runner-images-revision'):
        parser.add_argument('--'+name,required=True)
    for name in ('run-id','attempt'):
        parser.add_argument('--'+name,type=int,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    result=assemble(args.platforms,args.environment,args.backend_id,args.mesh_revision,args.runner_images_revision,args.run_id,args.attempt)
    args.output.write_text(json.dumps(result,indent=2)+'\n')


if __name__=='__main__':
    try:main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f'runner index assembly: {error}')
