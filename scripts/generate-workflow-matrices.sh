#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
descriptor="${1:-$repository_root/config/runner-image-families.json}"
runner_provider="${2:-github}"

[[ -f "$descriptor" ]] || {
  echo "runner image family descriptor does not exist: $descriptor" >&2
  exit 1
}
command -v jq >/dev/null || {
  echo "jq is required" >&2
  exit 1
}
[[ "$runner_provider" == github || "$runner_provider" == depot ]] || {
  echo "runner provider must be 'github' or 'depot': $runner_provider" >&2
  exit 1
}

if ! jq -e '
  def exact_keys($expected): (keys | sort) == ($expected | sort);
  def identifier: type == "string" and test("^[a-z0-9][a-z0-9-]*$");
  def tag_stem: type == "string" and test("^[a-z0-9][a-z0-9-]*$");
  def architectures:
    type == "array"
    and (length > 0)
    and (length == (unique | length))
    and all(.[]; . == "amd64" or . == "arm64");
  def backend:
    type == "object"
    and exact_keys([
      "architectures",
      "cuda_series",
      "id",
      "name",
      "rocm_version"
    ])
    and (.id | identifier)
    and (.name == "cpu" or .name == "vulkan" or .name == "cuda" or .name == "rocm")
    and (.architectures | architectures)
    and (
      if .name == "cpu" or .name == "vulkan" then
        .id == .name
        and .cuda_series == null
        and .rocm_version == null
        and .architectures == ["amd64", "arm64"]
      elif .name == "cuda" then
        (.cuda_series | type == "string" and test("^[0-9]+-[0-9]+$"))
        and .id == ("cuda" + (.cuda_series | split("-")[0]))
        and .rocm_version == null
        and .architectures == ["amd64", "arm64"]
      else
        .cuda_series == null
        and (.rocm_version | type == "string" and test("^[0-9]+(\\.[0-9]+){1,2}$"))
        and .id == (
          "rocm"
          + (.rocm_version | split(".")[0])
          + (.rocm_version | split(".")[1])
        )
        and .architectures == ["amd64"]
      end
    );
  def alias:
    type == "object"
    and exact_keys(["backend_id", "environment", "tag_stem"])
    and (.environment == "public" or .environment == "self-hosted")
    and (.backend_id | identifier)
    and (.tag_stem | tag_stem);
  def index:
    type == "object"
    and exact_keys([
      "architectures",
      "artifact",
      "backend_id",
      "backend_name",
      "cuda_series",
      "environment",
      "rocm_version",
      "tag_stem"
    ])
    and (.environment == "public" or .environment == "self-hosted")
    and (.backend_id | identifier)
    and .backend_name == "mixed"
    and .cuda_series == null
    and .rocm_version == null
    and (.architectures | architectures)
    and (.artifact | type == "string" and test("^candidate-index-[a-z0-9-]+$"))
    and (.tag_stem | tag_stem);

  . as $root
  | type == "object"
  and exact_keys(["aliases", "backends", "environments", "indexes", "schema"])
  and .schema == 1
  and .environments == ["public", "self-hosted"]
  and (.backends | type == "array" and length > 0 and all(.[]; backend))
  and ([.backends[].id] | length == (unique | length))
  and (.aliases | type == "array" and all(.[]; alias))
  and ([.aliases[] | [.environment, .backend_id]] | length == (unique | length))
  and all(
    .aliases[];
    . as $alias
    | any(
        $root.backends[];
        .id == $alias.backend_id
      )
  )
  and (.indexes | type == "array" and all(.[]; index))
  and ([.indexes[].artifact] | length == (unique | length))
  and (
    (
      [.environments[] as $environment | .backends[] | $environment + "-" + .id]
      + [.aliases[].tag_stem]
      + [.indexes[].tag_stem]
    )
    | length == (unique | length)
  )
' "$descriptor" >/dev/null; then
  echo "runner image family descriptor failed validation: $descriptor" >&2
  exit 1
fi

jq -ce \
  --arg runner_provider "$runner_provider" \
  '
  def platform($architecture):
    if $runner_provider == "github" and $architecture == "amd64" then
      {
        platform: "linux/amd64",
        platform_id: "amd64",
        runner: "ubuntu-24.04"
      }
    elif $runner_provider == "github" then
      {
        platform: "linux/arm64",
        platform_id: "arm64",
        runner: "ubuntu-24.04-arm"
      }
    elif $architecture == "amd64" then
      {
        platform: "linux/amd64",
        platform_id: "amd64",
        runner: "depot-ubuntu-24.04-16"
      }
    else
      {
        platform: "linux/arm64",
        platform_id: "arm64",
        runner: "depot-ubuntu-24.04-arm-16"
      }
    end;
  def families:
    . as $root
    | [
        $root.environments[] as $environment
        | $root.backends[]
        | {
            environment: $environment,
            backend_id: .id,
            backend_name: .name,
            cuda_series: (.cuda_series // "none"),
            rocm_version: (.rocm_version // "none"),
            architectures: (.architectures | join(",")),
            platform_matrix: {
              include: [.architectures[] | platform(.)]
            }
          }
      ];

  . as $root
  | (families) as $families
  | {
      family_matrix: {
        include: $families
      },
      promotion_matrix: {
        include: (
          [
            $families[]
            | . as $family
            | . + {
                artifact: ("candidate-index-" + .environment + "-" + .backend_id),
                tag_stem: (.environment + "-" + .backend_id),
                compatibility_tag_stem: (
                  [
                    $root.aliases[]
                    | select(
                        .environment == $family.environment
                        and .backend_id == $family.backend_id
                      )
                    | .tag_stem
                  ][0] // ""
                )
              }
            | del(.platform_matrix)
          ]
          + [
              $root.indexes[]
              | {
                  environment,
                  backend_id,
                  backend_name,
                  cuda_series: (.cuda_series // "none"),
                  rocm_version: (.rocm_version // "none"),
                  architectures: (.architectures | join(",")),
                  artifact,
                  tag_stem,
                  compatibility_tag_stem: ""
                }
            ]
        )
      }
    }
' "$descriptor"
