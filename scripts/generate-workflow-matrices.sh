#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
descriptor="${1:-$repository_root/config/runner-image-families.json}"

[[ -f "$descriptor" ]] || {
  echo "runner image family descriptor does not exist: $descriptor" >&2
  exit 1
}
command -v jq >/dev/null || {
  echo "jq is required" >&2
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
  # Every backend key is required except `environments`, which is optional
  # and defaults to every family environment when absent (so an existing
  # descriptor with no `environments` field is byte-identical in behavior).
  # When present it must be a non-empty, duplicate-free subset of the family
  # `.environments` — a typo like "pubic" must fail validation loudly rather
  # than silently produce an empty matrix for that backend.
  def has_valid_environments_subset($family_environments):
    (has("environments") | not)
    or (
      .environments
      | type == "array"
      and (length > 0)
      and (length == (unique | length))
      and all(.[]; . as $e | $family_environments | index($e) != null)
    );
  def backend($family_environments):
    type == "object"
    and ((keys - ["environments"]) | sort) == ([
      "architectures",
      "cuda_series",
      "id",
      "name",
      "rocm_version"
    ] | sort)
    and (keys - ["architectures", "cuda_series", "environments", "id", "name", "rocm_version"] | length == 0)
    and (has_valid_environments_subset($family_environments))
    and (.id | identifier)
    and (.name == "cpu" or .name == "vulkan" or .name == "cuda" or .name == "rocm" or .name == "web")
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
      elif .name == "rocm" then
        .cuda_series == null
        and (.rocm_version | type == "string" and test("^[0-9]+(\\.[0-9]+){1,2}$"))
        and .id == (
          "rocm"
          + (.rocm_version | split(".")[0])
          + (.rocm_version | split(".")[1])
        )
        and .architectures == ["amd64"]
      else
        .id == .name
        and .cuda_series == null
        and .rocm_version == null
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
  and (.backends | type == "array" and length > 0 and all(.[]; backend($root.environments)))
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
  # An alias must name an environment its own backend actually builds in —
  # otherwise it could claim e.g. a self-hosted-web alias that the matrix
  # below (scoped by backend.environments) will never produce.
  and all(
    .aliases[];
    . as $alias
    | ([$root.backends[] | select(.id == $alias.backend_id)][0]) as $backend
    | (($backend.environments // $root.environments) | index($alias.environment)) != null
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

jq -ce '
  def families:
    . as $root
    | [
        $root.backends[]
        | . as $backend
        | (.environments // $root.environments)[] as $environment
        | {
            environment: $environment,
            backend_id: $backend.id,
            backend_name: $backend.name,
            cuda_series: ($backend.cuda_series // "none"),
            rocm_version: ($backend.rocm_version // "none"),
            architectures: ($backend.architectures | join(","))
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
