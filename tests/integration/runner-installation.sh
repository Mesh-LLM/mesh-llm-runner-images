#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 2 && "$1" != -* && "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo 'usage: runner-installation.sh SELF_HOSTED_IMAGE EXPECTED_RUNNER_VERSION' >&2
  exit 2
}
image="$1"
expected_version="$2"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

docker image inspect "$image" > "$temporary/inspect.json"
jq -e 'length == 1 and .[0].Config.User == "runner"
  and .[0].Config.Entrypoint == ["/home/runner/run.sh"]
  and (.[0].Config.Env | index("MESH_RUNNER_ENVIRONMENT=self-hosted") != null)' \
  "$temporary/inspect.json" >/dev/null
docker history --no-trunc --format '{{.CreatedBy}}' "$image" > "$temporary/history.txt"
if grep -Eq 'install-actions-runner|actions-runner-linux-.*\.tar' "$temporary/history.txt"; then
  echo 'image contains an additional Actions runner installation' >&2
  exit 1
fi
# This exact base COPY is the sole runner distribution installation.
[[ "$(grep -Fc 'COPY --chown=runner:docker /actions-runner .' "$temporary/history.txt")" == 1 ]]
docker run --rm --pull never --network none --entrypoint /bin/bash \
  "$image" -ceu '
    [[ "$(id -u)" == 1001 ]]
    [[ "$(id -un)" == runner ]]
    test -x /home/runner/bin/Runner.Listener
    test -x /home/runner/run.sh
    for node_major in 20 24; do
      test -x "/__e/node$node_major/bin/node"
      "/__e/node$node_major/bin/node" --version
    done
  '
# Exercise the actual image entrypoint, not just the listener binary.
docker run --rm --pull never --network none "$image" --version \
  > "$temporary/runner.log" 2>&1
grep -Fxq "$expected_version" "$temporary/runner.log"
echo "Single Actions runner $expected_version and self-hosted entrypoint verified"
