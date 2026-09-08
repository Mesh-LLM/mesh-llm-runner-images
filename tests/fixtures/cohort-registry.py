#!/usr/bin/env python3
"""Deterministic metadata-only registry for publication failure-order tests."""
import json
import os
from pathlib import Path
import sys

state_path=Path(os.environ['COHORT_REGISTRY_STATE'])
state=json.loads(state_path.read_text())
arguments=sys.argv[1:]
with Path(os.environ['COHORT_REGISTRY_LOG']).open('a') as log:
    log.write(json.dumps(arguments)+'\n')
assert arguments[:2]==['buildx','imagetools'], arguments
if arguments[2]=='inspect':
    reference=arguments[3]
    if reference not in state['tags'] and reference not in state['indexes']:
        sys.exit('manifest unknown')
    digest=state['tags'].get(reference,reference.split('@')[-1])
    if '--raw' in arguments:
        print(json.dumps(state['indexes'][state['image']+'@'+digest]))
    else:
        print(json.dumps({'digest':digest}))
elif arguments[2]=='create':
    tags=[]
    position=3
    while arguments[position]=='--tag':
        tags.append(arguments[position+1]);position+=2
    assert len(arguments)==position+1 and '@sha256:' in arguments[position], arguments
    if os.environ.get('COHORT_FAIL_TAG') and any(os.environ['COHORT_FAIL_TAG'] in tag for tag in tags):
        sys.exit('injected publication failure')
    for tag in tags:
        state['tags'][tag]=arguments[position].split('@')[1]
    state_path.write_text(json.dumps(state))
else:
    raise AssertionError(arguments)
