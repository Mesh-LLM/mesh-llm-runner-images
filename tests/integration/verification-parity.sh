#!/usr/bin/env bash
set -euo pipefail

# Opt-in development proof: exercise Dockerfile.verify against an existing
# native image and export only its receipt. Nothing is published or pruned.
if [[ $# -lt 8 || $# -gt 9 || "$1" == -* ]]; then
  echo 'usage: verification-parity.sh LOCAL_IMAGE SSH_HOST ENV BACKEND MESH_SHA CUDA ROCM RUNNER_SHA [LOG_DIRECTORY]' >&2
  exit 2
fi
image="$1" ssh_host="$2" environment="$3" backend="$4" mesh_revision="$5"
cuda_series="$6" rocm_version="$7" runner_revision="$8"
[[ "$ssh_host" =~ ^[A-Za-z0-9_][A-Za-z0-9_.@-]*$ ]]
[[ "$mesh_revision" =~ ^[0-9a-f]{40}$ && "$runner_revision" =~ ^[0-9a-f]{40}$ ]]
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
export DOCKER_HOST="ssh://$ssh_host" PYTHONDONTWRITEBYTECODE=1
docker_command=(docker --host "$DOCKER_HOST")
verifier_revision="$(git -C "$repository_root" rev-parse HEAD)"
log_root="${9:-${TMPDIR:-/tmp}}"
mkdir -p "$log_root"
evidence="$(mktemp -d "$log_root/verification-parity.XXXXXX")"
evidence="$(cd "$evidence" && pwd -P)"
echo "Retaining verification parity proof in $evidence"
trap 'status=$?; if (( status != 0 )); then echo "Verification parity failed; evidence retained in $evidence" >&2; fi' EXIT

# Snapshot the exact Dockerfile and its COPY inputs; source revisions alone do
# not describe a development checkout with uncommitted verification changes.
context="$evidence/context"
mkdir -p "$context/config" "$context/scripts" "$evidence/binder" "$evidence/baseline"
cp "$repository_root"/{Dockerfile.verify,.dockerignore} "$context/"
test_dockerfile=Dockerfile
if [[ "$backend" == ui || "$backend" == browser ]]; then test_dockerfile=Dockerfile.ui; fi
cp "$repository_root/$test_dockerfile" "$evidence/production-dockerfile.txt"
# Execute the exact PR test block over the retained production image. Replacing
# only its FROM avoids unrelated dependency rewarming; it is not a full rebuild.
python3 -B - "$evidence/production-dockerfile.txt" "$context/Dockerfile.pr-test" "$environment" <<'PY'
import re, sys
from pathlib import Path
source, destination, environment = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
target = environment + '-test'
blocks = re.split(r'(?=^FROM )', source.read_text(), flags=re.M)
selected = [block for block in blocks if block.splitlines()[0] == f'FROM {environment} AS {target}']
assert len(selected) == 1, 'missing or duplicate PR test target'
instructions = selected[0].split('\n', 1)[1]
destination.write_text('# syntax=docker/dockerfile:1.7\nARG CANDIDATE_IMAGE\n'
    + 'FROM ${CANDIDATE_IMAGE} AS ' + target + '\n' + instructions
    + '\nFROM scratch AS identity-output\n'
    + f'COPY --from={target} /tmp/mesh-runner-identity.json /runtime-identity.json\n')
PY
cp "$repository_root"/config/{playwright-pin.txt,tool-pins.json,cache-policy.json,python-requirements.lock} "$context/config/"
cp "$repository_root"/scripts/{verify-runner-candidate.sh,verify-runner-image.sh,collect-runner-identity.py} "$context/scripts/"
cp "$repository_root"/scripts/{bind-runner-identity.py,measure-image-layers.py,collect-runner-identity.py} "$evidence/binder/"
cp "$repository_root/tests/integration/runner-identity.sh" "$evidence/baseline-helper.sh"
cp "${BASH_SOURCE[0]}" "$evidence/parity-helper.sh"
git -C "$repository_root" status --porcelain --untracked-files=all > "$evidence/checkout-status.txt"
python3 -B - "$evidence" "$repository_root" "$verifier_revision" <<'PY'
import hashlib, json, sys
from pathlib import Path
proof, repository, revision = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
files = sorted(path for folder in (proof / 'context', proof / 'binder') for path in folder.rglob('*') if path.is_file())
files += [proof / 'baseline-helper.sh', proof / 'parity-helper.sh', proof / 'production-dockerfile.txt']
entries = [{'path': str(path.relative_to(proof)), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()} for path in files]
(proof / 'inputs.json').write_text(json.dumps({'schema': 1, 'kind': 'development-checkout',
    'repository': repository, 'checkout_revision': revision,
    'checkout_dirty': bool((proof / 'checkout-status.txt').read_text()), 'files': entries}, indent=2) + '\n')
PY

"${docker_command[@]}" image inspect "$image" > "$evidence/image-before.json"
python3 -B - "$evidence/image-before.json" "$image" > "$evidence/candidate-reference.txt" <<'PY'
import json, re, sys
images = json.load(open(sys.argv[1]))
assert isinstance(images, list) and len(images) == 1, 'expected one local image'
image = images[0]
digest = image['Descriptor']['digest']
assert re.fullmatch(r'sha256:[0-9a-f]{64}', digest) and image['Id'] == digest, 'local image ID must address the OCI root'
assert image['Os'] == 'linux' and image['Architecture'] in {'amd64', 'arm64'}, 'unsupported image platform'
tags = sorted(image.get('RepoTags') or [])
supplied = sys.argv[2].split('@', 1)[0]
tag = supplied if supplied in tags else next(iter(tags), None)
assert tag and not tag.startswith('-') and '@' not in tag and ':' in tag.rsplit('/', 1)[-1], 'a retained local name:tag is required'
print(tag + '@' + digest)
PY
candidate_reference="$(cat "$evidence/candidate-reference.txt")"
image_id="$(jq -er '.[0].Id' "$evidence/image-before.json")"
architecture="$(jq -er '.[0].Architecture' "$evidence/image-before.json")"
"${docker_command[@]}" buildx inspect default > "$evidence/builder.txt"
grep -Eq '^Driver:[[:space:]]+docker[[:space:]]*$' "$evidence/builder.txt" || {
  echo 'verification parity requires the native Docker driver' >&2; exit 1;
}
daemon_platform="$("${docker_command[@]}" info --format '{{.OSType}}/{{.Architecture}}')"
case "$daemon_platform" in linux/x86_64) daemon_platform=linux/amd64 ;; linux/aarch64) daemon_platform=linux/arm64 ;; esac
[[ "$daemon_platform" == "linux/$architecture" ]] || { echo 'verification parity requires a native matching daemon' >&2; exit 1; }
printf '%s\n' "$daemon_platform" > "$evidence/daemon-platform.txt"

# The existing helper supplies independently bound raw OCI metadata and the
# offline runtime baseline. Its own proof directory remains intact below ours.
baseline_arguments=("$repository_root/tests/integration/runner-identity.sh" "$candidate_reference" "$ssh_host"
  "$environment" "$backend" "$mesh_revision" "$cuda_series" "$rocm_version" "$runner_revision" "$evidence/baseline")
jq -n --args '$ARGS.positional' -- "$BASH" "${baseline_arguments[@]}" > "$evidence/baseline-command.json"
"$BASH" "${baseline_arguments[@]}" 2>&1 | tee "$evidence/baseline.log"
shopt -s nullglob
baselines=("$evidence"/baseline/runner-identity.*)
[[ ${#baselines[@]} -eq 1 && -d "${baselines[0]}" ]]
baseline="${baselines[0]}"
for filename in playwright-pin.txt tool-pins.json cache-policy.json python-requirements.lock; do
  cmp "$context/config/$filename" "$baseline/expected/$filename"
done
for filename in verify-runner-candidate.sh verify-runner-image.sh collect-runner-identity.py; do
  cmp "$context/scripts/$filename" "$baseline/expected/$filename"
done
jq -e --arg digest "$image_id" --arg revision "$verifier_revision" '
  .passed == true and .digest == $digest and .verifier_checkout_revision == $revision
  and .hosted_workflow_qualified == false and .registry_publication_verified == false
' "$baseline/result.json" >/dev/null

build_verification() {
  local phase="$1" expected_source="$2"
  [[ ! -e "$evidence/$phase-output" ]]
  local dockerfile="$context/Dockerfile.verify" verification_target=verified
  if [[ "$phase" == pr-test ]]; then
    dockerfile="$context/Dockerfile.pr-test"
    verification_target="$environment-test"
  fi
  local arguments=(buildx build --builder default --pull=false --platform "linux/$architecture"
    --network none --no-cache-filter "$verification_target" --file "$dockerfile" --target identity-output
    --build-arg "CANDIDATE_IMAGE=$candidate_reference" --build-arg "VERIFIER_REVISION=$verifier_revision"
    --build-arg "BACKEND=$backend" --build-arg "MESH_LLM_REVISION=$expected_source"
    --build-arg "RUNNER_IMAGES_REVISION=$runner_revision" --build-arg "CUDA_SERIES=$cuda_series"
    --build-arg "ROCM_VERSION=$rocm_version"
    --build-arg "EXPECTED_ENVIRONMENT=$environment" --build-arg "EXPECTED_BACKEND=$backend"
    --build-arg "EXPECTED_MESH_REVISION=$expected_source" --build-arg "EXPECTED_RUNNER_IMAGES_REVISION=$runner_revision"
    --build-arg "EXPECTED_CUDA_SERIES=$cuda_series" --build-arg "EXPECTED_ROCM_VERSION=$rocm_version"
    --metadata-file "$evidence/$phase-build.json" --output "type=local,dest=$evidence/$phase-output"
    --progress plain "$context")
  jq -n --args '$ARGS.positional' -- "${docker_command[@]}" "${arguments[@]}" > "$evidence/$phase-command.json"
  "${docker_command[@]}" "${arguments[@]}" 2>&1 | tee "$evidence/$phase.log"
}
build_verification positive "$mesh_revision"
build_verification pr-test "$mesh_revision"
wrong_revision="0000000000000000000000000000000000000000"
if [[ "$mesh_revision" == "$wrong_revision" ]]; then wrong_revision="1111111111111111111111111111111111111111"; fi
if build_verification wrong-source "$wrong_revision"; then
  echo 'wrong source revision unexpectedly passed verification' >&2; exit 1;
fi
[[ ! -e "$evidence/wrong-source-output/runtime-identity.json" ]]

python3 -B - "$evidence" "$baseline" "$wrong_revision" "$environment" <<'PY'
import json, re, sys
from pathlib import Path
proof, baseline, wrong, environment = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4]
for phase, wanted in (('positive', 'DONE'), ('pr-test', 'DONE'), ('wrong-source', 'ERROR')):
    log = (proof / (phase + '.log')).read_text()
    target = environment + '-test' if phase == 'pr-test' else 'verified'
    runs = set(re.findall(r'^#(\d+) \[(?:linux/\S+ )?' + re.escape(target) + r' \d+/\d+\] RUN(?: |$)', log, re.M))
    assert len(runs) == 1, 'expected exactly one verification RUN in ' + phase
    step = runs.pop()
    statuses = set(re.findall(r'^#' + step + r' (DONE|CACHED|ERROR)(?::|\s|$)', log, re.M))
    assert statuses == {wanted}, 'verification RUN did not execute as expected: ' + phase
    if phase in ('positive', 'pr-test'):
        assert re.search(r'^#\d+ \[identity-output \d+/\d+\] COPY --from=' + re.escape(target) + ' ', log, re.M), 'missing actual scratch export COPY'
    else:
        assert "expected MeshLLM revision '" + wrong + "', found '" in log, 'negative failed for an unrelated reason'
for phase in ('positive', 'pr-test'):
    exported = proof / (phase + '-output/runtime-identity.json')
    assert exported.is_file() and not exported.is_symlink(), 'missing exported runtime receipt'
    assert json.loads(exported.read_text()) == json.loads((baseline / 'runtime-identity.json').read_text()), 'Dockerfile/runtime baseline mismatch'
PY
python3 -B "$evidence/binder/bind-runner-identity.py" --runtime "$evidence/positive-output/runtime-identity.json" \
  --candidate "$baseline/candidate.json" --index "$baseline/index.json" --manifest "$baseline/manifest.json" \
  --expected-directory "$baseline/expected" --verifier-revision "$verifier_revision" --output "$evidence/identity.json"
"${docker_command[@]}" image inspect "$image" > "$evidence/image-after.json"
"${docker_command[@]}" image inspect "$candidate_reference" > "$evidence/candidate-after.json"
python3 -B - "$evidence" "$baseline" "$candidate_reference" <<'PY'
import hashlib, json, sys
from pathlib import Path
proof, baseline, reference = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
before = json.loads((proof / 'image-before.json').read_text())[0]
for name in ('image-after.json', 'candidate-after.json'):
    after = json.loads((proof / name).read_text())[0]
    assert after['Id'] == before['Id'] and after['Descriptor'] == before['Descriptor'], 'retained image identity changed'
assert json.loads((proof / 'identity.json').read_text()) == json.loads((baseline / 'identity.json').read_text()), 'bound receipt differs from baseline'
inputs = json.loads((proof / 'inputs.json').read_text())
for entry in inputs['files']:
    assert hashlib.sha256((proof / entry['path']).read_bytes()).hexdigest() == entry['sha256'], 'captured verification input changed'
(proof / 'result.json').write_text(json.dumps({'schema': 1, 'kind': 'local-native-verification-parity-development-proof',
    'passed': True, 'candidate_reference': reference, 'digest': before['Id'],
    'checkout_revision': inputs['checkout_revision'], 'checkout_dirty': inputs['checkout_dirty'],
    'runtime_receipts_equal': True, 'wrong_source_rejected': True, 'image_identity_unchanged': True,
    'pr_test_block_executed': True, 'full_production_rebuild': False,
    'hosted_workflow_qualified': False, 'registry_publication_verified': False,
    'network_scope': 'Verification RUN has no network; image/frontend resolution is outside this isolation.'}, indent=2) + '\n')
PY
echo "Native verification parity proof passed: $evidence"
