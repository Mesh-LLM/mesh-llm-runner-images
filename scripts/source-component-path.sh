#!/usr/bin/env bash
# Resolve supported source layouts without changing dependency paths or bytes.
source_component_path() {
  local root="$1" component="$2" optional="${3:-false}"
  local candidates=() found=() relative part current
  case "$component" in
    ui) candidates=(crates/mesh-llm-ui mesh/crates/mesh-llm-ui) ;;
    website) candidates=(website mesh/website) ;;
    *) echo "unsupported source component: $component" >&2; return 1 ;;
  esac
  for relative in "${candidates[@]}"; do
    if [[ -e "$root/$relative" || -L "$root/$relative" ]]; then
      current="$root"
      local parts=()
      IFS=/ read -r -a parts <<< "$relative"
      for part in "${parts[@]}"; do
        current="$current/$part"
        [[ ! -L "$current" ]] || {
          echo "source component directories must not be symlinks: $relative" >&2
          return 1
        }
      done
      [[ -d "$root/$relative" ]] || {
        echo "source component must be a directory: $relative" >&2
        return 1
      }
      found+=("$relative")
    fi
  done
  if (( ${#found[@]} == 0 )) && [[ "$optional" == true ]]; then return 0; fi
  (( ${#found[@]} == 1 )) || {
    echo "expected exactly one $component source layout, found ${#found[@]}" >&2
    return 1
  }
  printf '%s\n' "${found[0]}"
}
