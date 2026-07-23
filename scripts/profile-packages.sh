#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "usage: profile-packages.sh PROFILE.yml [...]" >&2
  exit 2
fi

read_profile() {
  local profile_file="$1"
  local line package profile_name
  local packages_started=0
  local packages_found=0

  [[ -f "$profile_file" ]] || {
    echo "profile does not exist: $profile_file" >&2
    return 1
  }

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      ""|---|"schema: 1"|apt:|\#*) ;;
      "profile: "*)
        profile_name="${line#"profile: "}"
        [[ "$profile_name" =~ ^[a-z][a-z0-9-]*$ ]] || {
          echo "invalid profile name in $profile_file: $profile_name" >&2
          return 1
        }
        ;;
      "  packages:")
        packages_started=1
        packages_found=1
        ;;
      "  packages: []")
        packages_started=0
        packages_found=1
        ;;
      "    - "*)
        [[ "$packages_started" -eq 1 ]] || {
          echo "package entry appears outside apt.packages in $profile_file: $line" >&2
          return 1
        }
        package="${line#"    - "}"
        [[ "$package" =~ ^[a-z0-9][a-z0-9.+-]*$ ]] || {
          echo "invalid apt package in $profile_file: $package" >&2
          return 1
        }
        printf '%s\n' "$package"
        ;;
      *)
        echo "unsupported profile YAML in $profile_file: $line" >&2
        return 1
        ;;
    esac
  done < "$profile_file"

  [[ "$packages_found" -eq 1 ]] || {
    echo "profile has no apt.packages key: $profile_file" >&2
    return 1
  }
}

for profile_file in "$@"; do
  read_profile "$profile_file"
done | sort -u
