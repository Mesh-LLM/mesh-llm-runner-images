#!/usr/bin/env bash
set -euo pipefail

destination="${1:?usage: install-actionlint.sh DESTINATION}"
version=1.7.12
archive="actionlint_${version}_linux_amd64.tar.gz"
expected_sha256=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

mkdir -p "$destination" "$temporary_directory/extract"
curl --proto '=https' --tlsv1.2 -fsSL \
  "https://github.com/rhysd/actionlint/releases/download/v${version}/${archive}" \
  -o "$temporary_directory/$archive"
printf '%s  %s\n' "$expected_sha256" "$temporary_directory/$archive" | sha256sum -c -

tar -xzf "$temporary_directory/$archive" -C "$temporary_directory/extract" actionlint
[[ -f "$temporary_directory/extract/actionlint" && ! -L "$temporary_directory/extract/actionlint" ]] || {
  echo "verified actionlint archive did not contain a regular actionlint binary" >&2
  exit 1
}
install -m 0755 "$temporary_directory/extract/actionlint" "$destination/actionlint"
"$destination/actionlint" -version
