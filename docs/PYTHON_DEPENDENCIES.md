# Python dependency lock

`config/python-requirements.lock` records the 71 runtime packages observed in
the verified Stage 2 Linux ARM64 image. It excludes `pip`, which belongs to the
Python/venv bootstrap. The same lock must install and pass `pip check` on both
Linux AMD64 and ARM64 before a cohort is promoted.

The image installs every exact entry with `--no-deps`, then checks the installed
dependency closure. MeshLLM's `ci/requirements-ci-python.txt` is a compatibility
requirement, not a second installation source: an offline pip dry run must
propose no changes. A new missing dependency or incompatible version stops the
build and requests a reviewed lock refresh. When that source manifest is absent,
the image still installs the frozen runtime and skips only this compatibility
probe.

For an intentional refresh, use a disposable environment matching the image's
Ubuntu/Python version. Resolve the selected MeshLLM source requirements there,
validate the environment, and capture a candidate lock:

```bash
python3 -m venv /tmp/mesh-python-lock-refresh
/tmp/mesh-python-lock-refresh/bin/pip install -r /path/to/mesh-llm/ci/requirements-ci-python.txt
/tmp/mesh-python-lock-refresh/bin/pip check
/tmp/mesh-python-lock-refresh/bin/pip freeze --all | sed '/^pip==/d' > /tmp/python-requirements.lock.candidate
```

Review the complete version diff before replacing the checked-in lock. Build
and verify the CPU image on both architectures, including the source requirement
probe and existing Python import checks. The opt-in dependency-cache integration
test additionally checks venv permissions for both root and runner. Run
`bash tests/integration/python-lock.sh IMAGE` to compare every installed runtime
package against the source lock and check the closure without network access. A successful
resolution on one architecture alone does not qualify the shared lock.
