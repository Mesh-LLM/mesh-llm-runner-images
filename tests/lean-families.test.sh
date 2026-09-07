#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
catalog="$repository_root/config/runner-image-families.json"
generator="$repository_root/scripts/generate-workflow-matrices.sh"
selector="$repository_root/scripts/validate-family-selection.sh"
validator="$repository_root/scripts/validate-candidate-descriptor.sh"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

expect_failure() {
  if "$@" > "$temporary/failure.log" 2>&1; then
    echo "expected rejection: $*" >&2
    exit 1
  fi
}

matrices="$("$BASH" "$generator" "$catalog")"
jq -e '
  ([.family_matrix.include[].architectures | split(",") | length] | add) == 23
  and all(.family_matrix.include[];
    if .backend_id == "ui" or .backend_id == "browser" then
      .environment == "public" and .architectures == "amd64" and .dockerfile == "Dockerfile.ui"
    else .dockerfile == "Dockerfile" end)
  and all(.promotion_matrix.include[]; has("dockerfile") | not)
' <<< "$matrices" >/dev/null

# Explicit legacy defaults cannot change any normalized family or promotion.
jq '(.backends[] | select(.name != "ui" and .name != "browser") | .dockerfile) = "Dockerfile"' \
  "$catalog" > "$temporary/explicit-default.json"
[[ "$("$BASH" "$generator" "$temporary/explicit-default.json")" == "$matrices" ]]

for mutation in \
  '(.backends[] | select(.id == "ui") | .dockerfile) = null' \
  '(.backends[] | select(.id == "ui")) |= del(.dockerfile)' \
  '(.backends[] | select(.id == "ui") | .dockerfile) = "Dockerfile"' \
  '(.backends[] | select(.id == "browser") | .dockerfile) = "../Dockerfile.ui"' \
  '(.backends[] | select(.id == "cpu") | .dockerfile) = "Dockerfile.ui"' \
  '(.backends[] | select(.id == "cpu") | .dockerfile) = null' \
  '(.backends[] | select(.id == "ui")) |= del(.environments)' \
  '(.backends[] | select(.id == "browser") | .environments) = ["self-hosted"]' \
  '(.backends[] | select(.id == "ui") | .architectures) = ["amd64", "arm64"]'; do
  jq "$mutation" "$catalog" > "$temporary/invalid.json"
  expect_failure "$BASH" "$generator" "$temporary/invalid.json"
done

"$BASH" "$selector" public cpu cpu none none amd64 Dockerfile
"$BASH" "$selector" self-hosted cuda12 cuda 12-9 none amd64,arm64 Dockerfile
for family in ui browser; do
  "$BASH" "$selector" public "$family" "$family" none none amd64 Dockerfile.ui
  expect_failure "$BASH" "$selector" public "$family" "$family" none none amd64 Dockerfile
  expect_failure "$BASH" "$selector" self-hosted "$family" "$family" none none amd64 Dockerfile.ui
  expect_failure "$BASH" "$selector" public "$family" "$family" none none amd64,arm64 Dockerfile.ui
done
expect_failure "$BASH" "$selector" public cpu cpu none none amd64 Dockerfile.ui
expect_failure "$BASH" "$selector" public cpu cpu none none 'amd64,amd64' Dockerfile
expect_failure "$BASH" "$selector" public cuda12 cuda 13-1 none amd64 Dockerfile

for family in ui browser; do
  descriptor="$temporary/$family.json"
  jq --arg family "$family" '
    .backend = {id:$family,name:$family,cuda_series:null,rocm_version:null}
    | .children = [.children[0]]
  ' "$repository_root/tests/fixtures/candidate-index-valid.json" > "$descriptor"
  arguments=(--descriptor "$descriptor" --image ghcr.io/mesh-llm/mesh-llm-cuda-runner
    --environment public --backend-id "$family" --backend-name "$family"
    --cuda-series none --rocm-version none --architectures amd64
    --mesh-revision 2222222222222222222222222222222222222222
    --runner-images-revision 1111111111111111111111111111111111111111)
  "$BASH" "$validator" "${arguments[@]}"
  expect_failure "$BASH" "$validator" "${arguments[@]}" --environment self-hosted
  expect_failure "$BASH" "$validator" "${arguments[@]}" --architectures arm64
  expect_failure "$BASH" "$validator" "${arguments[@]}" --cuda-series 12-9
done

# The catalog check must execute before any image-building authentication.
python3 - "$repository_root/.github/workflows/stage-image-family.yml" <<'PY'
import pathlib
import sys
workflow = pathlib.Path(sys.argv[1]).read_text()
check = workflow.index('- name: Validate catalog build selection')
assert workflow.index('- name: Checkout runner image sources') < check
assert check < workflow.index('- name: Set up Depot CLI')
assert check < workflow.index('- name: Log in to GHCR for candidate staging')
assert 'scripts/validate-family-selection.sh' in workflow[check:workflow.index('- name: Download manifest bundles')]
PY
echo 'Lean family catalog, selection, and candidate contracts passed'
