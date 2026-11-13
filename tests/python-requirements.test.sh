#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# Execute the runtime proof's actual parser without needing a Docker image.
python3 - "$repository_root/tests/integration/python-lock.sh" <<'PY'
import pathlib
import re
import sys
source = pathlib.Path(sys.argv[1]).read_text()
parser = source[source.index('expected = {}'):source.index('installed = {}')]
def parse(lock):
    namespace = {'lock': lock.encode(), 're': re, 'normalize': lambda name: re.sub(r'[-_.]+', '-', name).lower()}
    exec(parser, namespace)
    return namespace['expected']
assert parse('# comment\n\nmesh_fixture==1.0.0\n  \n') == {'mesh-fixture': '1.0.0'}
for invalid in ['mesh>=1.0\n', 'mesh==\n', 'mesh_fixture==1.0\nmesh-fixture==1.0\n']:
    try:
        parse(invalid)
    except AssertionError:
        pass
    else:
        raise AssertionError(f'invalid lock accepted: {invalid}')
PY
