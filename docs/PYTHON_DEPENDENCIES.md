# Python dependency lock

Full runner images install the exact packages in `config/python-requirements.lock`
to provide the Hugging Face `hf` CLI. MeshLLM uses this CLI to download pinned
models on cache misses and publish model artifacts. The lean UI and browser images
use standard-library Python and do not install this environment.

MeshLLM's SDK compatibility tests create a separate environment from the
external SDK's hash-locked requirements. The runner image's Python lock does
not supply or validate those clients.

To refresh the CLI, resolve its pinned version and its complete dependency
closure using Python 3.12 in a disposable Ubuntu environment. Review the
resulting exact package versions before replacing the lock. The image installs
the lock with `--no-deps`, runs `pip check`, and verifies `hf --help` offline.
Build and verify the CPU image on both AMD64 and ARM64 before promotion; a
successful resolution on one architecture alone does not qualify the lock.

Run `bash tests/integration/python-lock.sh IMAGE` to compare the installed
packages against the lock and check their dependency closure without network
access. The opt-in dependency-cache integration test also checks venv
permissions for root and runner.
