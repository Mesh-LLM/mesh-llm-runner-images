#!/usr/bin/env bash
set -euo pipefail
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
python3 -B "$repository_root/tests/fixtures/build_metrics.py"
