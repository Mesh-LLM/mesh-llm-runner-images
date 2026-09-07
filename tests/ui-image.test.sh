#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT
export UI_FIXTURE_ROOT="$temporary_directory"
unset MESH_SOURCE_REVISION
mkdir -p "$temporary_directory/bin" "$temporary_directory/source" "$temporary_directory/logs"
export PATH="$temporary_directory/bin:$PATH"

cat > "$temporary_directory/bin/git" <<'PY'
#!/usr/bin/env python3
import os
import sys
from pathlib import Path

assert sys.argv[1] == "-C"
expected_revision = os.environ.get("UI_FIXTURE_EXPECTED_REVISION", "cd602d6cba0f505fd9e1b4a6b5d1ca261a0032a0")
assert sys.argv[-1].removesuffix("^{commit}") == expected_revision
if sys.argv[3] == "archive":
    if os.environ.get("UI_FIXTURE_ARCHIVE_FAILURE"):
        sys.exit(13)
    sys.stdout.buffer.write((Path(os.environ["UI_FIXTURE_ROOT"]) / "source.tar").read_bytes())
else:
    assert sys.argv[3:5] == ["cat-file", "-e"]
PY
cat > "$temporary_directory/bin/docker" <<'PY'
#!/usr/bin/env python3
import io
import json
import os
import sys
import tarfile
from pathlib import Path

root = Path(os.environ["UI_FIXTURE_ROOT"])
args = sys.argv[1:]
if args[0] == "info":
    print(os.environ.get("UI_FIXTURE_DAEMON_ARCH", "x86_64"))
elif args[:2] == ["image", "inspect"]:
    print((root / "image.json").read_text())
elif args[0] == "run":
    assert args[args.index("--network") + 1] == "none"
    assert args[args.index("--platform") + 1] == "linux/amd64"
    assert args[args.index("--user") + 1] == "root"
    assert "HOME=/github/home" in args and "CI=true" in args
    assert "--pull=never" in args and not {"--mount", "--volume", "-v"}.intersection(args)
    assert args[args.index("--entrypoint") + 2] == "sha256:" + "a" * 64
    assert args[-2] == os.environ.get("UI_FIXTURE_EXPECTED_REVISION", "cd602d6cba0f505fd9e1b4a6b5d1ca261a0032a0")
    assert "pnpm install --offline --frozen-lockfile --ignore-scripts=false\n" in args[args.index("-c") + 1]
    source = sys.stdin.buffer.read()
    if source:
        with tarfile.open(fileobj=io.BytesIO(source)) as archive:
            assert archive.extractfile("immutable-source.txt").read() == b"immutable source fixture\n"
    (root / "run.json").write_text(json.dumps(args))
    sys.exit(int(os.environ.get("UI_FIXTURE_DOCKER_EXIT", "0")))
else:
    raise AssertionError(args)
PY
chmod +x "$temporary_directory/bin/git" "$temporary_directory/bin/docker"
printf 'immutable source fixture\n' > "$temporary_directory/source/immutable-source.txt"
tar -cf "$temporary_directory/source.tar" -C "$temporary_directory/source" immutable-source.txt
jq -n '[{Id: ("sha256:" + ("a" * 64)), Os: "linux", Architecture: "amd64", Config: {
  Env: ["MESH_RUNNER_BACKEND=browser"], Labels: {
    "io.mesh-llm.source.revision": "cd602d6cba0f505fd9e1b4a6b5d1ca261a0032a0",
    "io.mesh-llm.runner-images.revision": ("b" * 40)
  }}}]' > "$temporary_directory/image.json"
helper="$repository_root/tests/integration/ui-image.sh"
bash "$helper" mutable-tag "$temporary_directory/source" "$temporary_directory/logs" >/dev/null
result="$(find "$temporary_directory/logs" -name result.json)"
jq -e '.passed and .lifecycle_scripts_enabled and .network == "none" and .image_id == ("sha256:" + ("a" * 64))' "$result" >/dev/null

expect_failure() {
  local case_name="$1"
  shift
  mkdir "$temporary_directory/$case_name"
  if env "$@" bash "$helper" mutable-tag "$temporary_directory/source" "$temporary_directory/$case_name" > "$temporary_directory/failure.log" 2>&1; then
    echo "expected UI qualification failure: $case_name" >&2; exit 1
  fi
  test -z "$(find "$temporary_directory/$case_name" -name result.json)"
}
expect_failure daemon-arch UI_FIXTURE_DAEMON_ARCH=aarch64
expect_failure archive-failure UI_FIXTURE_ARCHIVE_FAILURE=1
expect_failure docker-failure UI_FIXTURE_DOCKER_EXIT=19
rm "$temporary_directory/run.json"
for invalid_revision in main cd602d6 '' CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC; do
  expect_failure "invalid-source-${#invalid_revision}" "MESH_SOURCE_REVISION=$invalid_revision"
  grep -q 'MESH_SOURCE_REVISION must be a full lowercase git SHA' "$temporary_directory/failure.log"
  test ! -e "$temporary_directory/run.json"
done
override_revision=cccccccccccccccccccccccccccccccccccccccc
expect_failure source-mismatch "MESH_SOURCE_REVISION=$override_revision" "UI_FIXTURE_EXPECTED_REVISION=$override_revision"
grep -q "image must be Linux AMD64 and declare MeshLLM source revision $override_revision" "$temporary_directory/failure.log"
test ! -e "$temporary_directory/run.json"
jq --arg revision "$override_revision" '.[0].Config.Labels["io.mesh-llm.source.revision"] = $revision' \
  "$temporary_directory/image.json" > "$temporary_directory/override-image.json"
mv "$temporary_directory/override-image.json" "$temporary_directory/image.json"
MESH_SOURCE_REVISION="$override_revision" UI_FIXTURE_EXPECTED_REVISION="$override_revision" \
  bash "$helper" mutable-tag "$temporary_directory/source" "$temporary_directory/override-logs" >/dev/null
override_result="$(find "$temporary_directory/override-logs" -name result.json)"
jq -e --arg revision "$override_revision" '.passed and .source_revision == $revision' "$override_result" >/dev/null

# When pnpm is available, exercise its actual flag precedence with no package
# downloads. This remains optional for the standard Bash/Python host suites.
if command -v pnpm >/dev/null; then
  lifecycle_fixture="$temporary_directory/lifecycle"
  mkdir -p "$lifecycle_fixture" "$temporary_directory/pnpm-home"
  cat > "$lifecycle_fixture/package.json" <<'JSON'
{"name":"mesh-lifecycle-fixture","private":true,"scripts":{"postinstall":"printf executed > lifecycle.marker"}}
JSON
  cat > "$lifecycle_fixture/pnpm-lock.yaml" <<'YAML'
lockfileVersion: '9.0'
settings:
  autoInstallPeers: true
  excludeLinksFromLockfile: false
importers:
  .: {}
YAML
  printf 'ignore-scripts=true\nstore-dir=%s\n' "$temporary_directory/pnpm-store" > "$lifecycle_fixture/.npmrc"
  env CI=true HOME="$temporary_directory/pnpm-home" npm_config_ignore_scripts=true \
    pnpm --dir "$lifecycle_fixture" install --offline --frozen-lockfile > "$temporary_directory/ignored-install.log" 2>&1
  test ! -e "$lifecycle_fixture/lifecycle.marker"
  read -r -a install_arguments <<< "$(awk '/^pnpm install / { print }' "$helper")"
  env CI=true HOME="$temporary_directory/pnpm-home" npm_config_ignore_scripts=true \
    pnpm --dir "$lifecycle_fixture" "${install_arguments[@]:1}" > "$temporary_directory/enabled-install.log" 2>&1
  grep -Fxq executed "$lifecycle_fixture/lifecycle.marker"
  echo "Real pnpm $(pnpm --version) CLI flag overrides ignore-scripts in environment and project config"
else
  echo 'Skipping optional real pnpm precedence fixture: pnpm is unavailable'
fi

# Execute the embedded scanner against real files and pnpm content-hash indexes.
python3 - "$helper" "$temporary_directory" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

helper, root = map(Path, sys.argv[1:])
script = helper.read_text().split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
scanner = root / "scanner.py"
scanner.write_text(script)
store = root / "store"
store.mkdir()
modules = root / "node_modules"
modules.mkdir()
command = [sys.executable, str(scanner), str(modules), str(store)]

def check(expected):
    result = subprocess.run(command, capture_output=True, text=True)
    assert (result.returncode == 0) == expected, result.stdout + result.stderr

(modules / "libonnxruntime.so.1.21.0").touch()
(store / "cpu.json").write_text(json.dumps({"files": {"bin/libonnxruntime_providers_shared.so": {"integrity": "sha512-fixture"}}}))
check(True)
gpu = modules / "libonnxruntime_providers_cuda.so"
gpu.touch()
check(False)
gpu.unlink()
(store / "gpu.json").write_text(json.dumps({"sideEffects": {"linux-x64": {"files": {"bin/libonnxruntime_providers_tensorrt.so": {"integrity": "sha512-fixture"}}}}}))
check(False)
PY
echo 'UI qualification source streaming, immutable image, failure propagation, and GPU scanner fixtures passed'
