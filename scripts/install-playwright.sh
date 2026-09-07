#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/install-tools-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/install-tools-common.sh"

install_playwright() {
  local pin_file="${1:?Playwright pin file is required}"
  local metadata_root="${2:-/etc}"
  local PLAYWRIGHT_VERSION installed_version chromium_directory
  : "${PLAYWRIGHT_BROWSERS_PATH:?Playwright browser directory is required}"
  PLAYWRIGHT_VERSION="$(cat "$pin_file")"
  validate_exact_versions PLAYWRIGHT_VERSION
  # A global playwright package makes require('playwright') available through
  # NODE_PATH; @playwright/test alone nests it below another package.
  npm install --global "playwright@${PLAYWRIGHT_VERSION}"
  installed_version="$(playwright --version | head -n1 | awk '{print $NF}')"
  verify_installed_version playwright "$PLAYWRIGHT_VERSION" "$installed_version"
  mkdir -p "$PLAYWRIGHT_BROWSERS_PATH" "$metadata_root"
  PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD='' playwright install-deps chromium
  PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD='' playwright install chromium
  chromium_directory="$(find "$PLAYWRIGHT_BROWSERS_PATH" -mindepth 1 -maxdepth 1 -type d -name 'chromium-*' -print -quit)"
  [[ -n "$chromium_directory" ]] || { echo "Playwright did not install Chromium" >&2; return 1; }
  basename "$chromium_directory" > "$metadata_root/mesh-runner-chromium-build"
  chown -R runner:docker "$PLAYWRIGHT_BROWSERS_PATH"
  printf '%s\n' "$installed_version" > "$metadata_root/mesh-runner-playwright-version"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  install_playwright "$@"
fi
