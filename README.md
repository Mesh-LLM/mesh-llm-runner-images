# MeshLLM runner images

This repository builds full MeshLLM CI images and smaller UI images on the same pinned Actions runner base. Every native-runtime backend is available as a GitHub-hosted job container (`public`) and an image containing the GitHub Actions runner (`self-hosted`):

- `public-cpu-*` / `self-hosted-cpu-*`
- `public-vulkan-*` / `self-hosted-vulkan-*`
- `public-cuda12-*` / `self-hosted-cuda12-*`
- `public-cuda13-*` / `self-hosted-cuda13-*`
- `public-rocm70-*` / `self-hosted-rocm70-*`
- `public-rocm72-*` / `self-hosted-rocm72-*`

CPU, Vulkan, and CUDA tags support `linux/amd64` and `linux/arm64`. ROCm tags are intentionally `linux/amd64` only because that is the currently supported MeshLLM ROCm CI target. The compatibility aliases preserve the existing image contract: `public-*` is CPU on both architectures, while `self-hosted-*` combines CUDA 12 on AMD64 with CPU on ARM64. The existing GHCR package name is retained to avoid a registry and credential migration.

The `web` backend is public-only and AMD64-only. It adds pinned Chromium to the full compiler and Python environment for website documentation, browser tests, and nightly stability consumers.

The public-only AMD64 `ui` and `browser` families use `Dockerfile.ui`. `public-ui-*` provides Node, pnpm, standard-library Python, archives and a dedicated UI dependency store. `public-browser-*` also includes pinned Chromium. Both retain the Actions Node paths and omit the compiler toolchains, Cargo stores and AI Python environment.

Use these smaller families for ordinary UI quality, distribution builds and E2E tests. Release UI preparation still calls Cargo and Perl through `release-version.sh`; website builds call `crate-docs`; nightly stability uses AI dependencies. Those consumers retain the full images. Consumer adoption requires a qualified immutable digest.

## Design

The image has four layers of configuration:

1. `profiles/common.yml` is the shared operating-system toolchain found in MeshLLM CI and build scripts.
2. `profiles/backends/*.yml` contains CPU, Vulkan, CUDA, ROCm, or Web SDK packages; the owning installer handles vendor repositories and compilers. `web`'s stays an empty `apt.packages` list — Chromium's system dependencies are `playwright install-deps chromium`'s to own, not ours; see below.
3. `profiles/public.yml` and `profiles/self-hosted.yml` contain environment-only additions.
4. `scripts/prepare-build-context.sh` reads a MeshLLM checkout, discovers its Rust, Node, Python, and Go manifests, and creates one bundle per runner environment. The Docker build warms Cargo, pnpm, npm, and Python dependencies in a shared stage.

The YAML profiles use a deliberately small schema (`schema`, `profile`, and `apt.packages`) that is parsed by portable Bash without Python or Ruby. Each bundle separates `dependencies/` from its audit files. `dependencies/dependency-index.json` hashes the manifests, package-manager configuration, and generated Cargo target stubs. `manifest-index.json`, `source-revision.txt`, and `profile.txt` record provenance outside that payload. Cargo target stubs retain the workspace graph without copying MeshLLM source code into the image.

The common toolchain feeds independent SDK and dependency stages. Final images
copy the populated dependency stores with `COPY --link`, then add environment
packages and provenance. A source-only revision change preserves the dependency
cache; a dependency change preserves SDK installation. Both environments use the
same dependency payload and stores.

The npm cache and pnpm store have explicit paths under `/home/runner`, so Actions'
`HOME=/github/home` does not hide them. Warming removes temporary `node_modules`
trees before the layer is saved. Jobs install their own checkout from the baked
stores, which are writable by root and runner.

Lean UI warming selects only root/UI package-manager inputs and keeps provenance
outside the dependency payload. It builds a fresh pnpm store with
`ONNXRUNTIME_NODE_INSTALL=skip`, the pinned ONNX package's supported way to skip
optional CUDA/TensorRT downloads. The package retains its CPU library and Node
binding. The lean image keeps this setting for downstream installs. Its store
must remain separate from full images because pnpm's lifecycle cache key does
not include that environment variable.

### Base image

The toolchain stage builds from `ACTIONS_RUNNER_BASE_IMAGE`, whose default is
`ghcr.io/actions/actions-runner:latest` pinned by digest in the Dockerfile. It
provides the GitHub Actions runner agent, the `runner` user (uid 1001), the
`docker` group (gid 123), `/usr/bin/docker` (Docker CLI, no daemon), and Node 20
and 24 runtimes under `/home/runner/externals/node{20,24}/bin`.
`scripts/install-core-tools.sh` wires Node from these externals into
`/usr/local/bin` instead of installing Node from an apt repository;
`docker-ce-cli` is no longer apt-installed because the base already ships a
compatible Docker client.

The self-hosted target reuses that same runner installation and its entrypoint.
The base digest owns the runner and bundled Node versions. `PNPM_VERSION` and
`RUST_VERSION` pin the additional tools, and `config/python-requirements.lock`
pins the Python runtime dependency closure. Rebuilding validates installed tool
versions and checks that the selected MeshLLM Python requirements need no changes
to that closure. See `docs/PYTHON_DEPENDENCIES.md` for lock refreshes.

Trusted staging/promotion may replace only the registry/repository portion with
a Depot Registry pull-through mirror while retaining the exact upstream digest.
The opt-in gate, repository mapping, short-lived pull-token authentication, and
rollback procedure are documented in `docs/OPERATIONS.md`. Validation and pull
request builds always use the canonical upstream reference.

Both final stages provision the GitHub Actions root-system conventions required when the image is used as a job `container:` (DinD sidecar, rootless Podman, or any setup where the runner cannot rely on kubelet bind mounts):

- `/__e/node24` → symlinked to `/home/runner/externals/node24`
- `/__e/node20` → symlinked to `/home/runner/externals/node20`
- `/__w`, `/github/home`, `/github/workflow` → directories with mode 0777

The `public` stage bakes these as `USER root` (matching the public-container root convention); the `self-hosted` stage bakes them before restoring `USER runner` so the runner agent's `run.sh` entrypoint still executes with uid 1001. `scripts/verify-runner-image.sh` asserts both the `/__e/node24/bin/node` symlink and its canonical source under `/home/runner/externals/`, plus `docker --version`, so regressions of the `/__e/node24/bin/node: no such file or directory` failure mode are caught at build time.

### Playwright / Chromium version pin

`config/playwright-pin.txt` is the single declared source of truth for the
Chromium build baked into `public-web` and `public-browser`. Their shared installer
installs the `playwright` package at that exact version, runs `playwright
install-deps chromium` (so Playwright's own dependency list drives apt, not a
hand-maintained one) and `playwright install chromium` into a fixed
`PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright`, and records what it actually
got in `/etc/mesh-runner-playwright-version` and `/etc/mesh-runner-chromium-build`
(the latter read from the installed browser directory name, not hand-written).
`PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` is baked as an image env var so a stray
`pnpm install` postinstall never re-downloads a browser into a running
container; Playwright hard-errors instead of downloading when a browser is
missing (`scripts/verify-runner-image.sh` checks both browser-capable families by
launching Chromium headless, offline, and closing it).

This image is the stable side of the version pairing: it does not read
MeshLLM's `pnpm-lock.yaml` at build time, and MeshLLM does not re-derive its
pin from this image. Each side asserts the other's value independently —
`verify-runner-image` takes an optional expected Playwright version argument,
and MeshLLM's own CI checks its `@playwright/test` resolution against
`/etc/mesh-runner-playwright-version` before trusting the image. Bumping the
pin has a mandatory order (this repo promotes first, MeshLLM bumps its
lockfile second); see `docs/OPERATIONS.md`.

## Local build

```bash
scripts/prepare-build-context.sh /Users/ndizazzo/dev/mesh/mesh-llm

docker buildx build \
  --platform linux/amd64 \
  --target public \
  --build-arg ACTIONS_RUNNER_BASE_IMAGE=ghcr.io/actions/actions-runner:latest@sha256:0cfdcc701ce933c6d243c6b0b2da767366dc9f2e99961d4c3754b0b78084cdda \
  --build-arg BACKEND=cpu \
  --build-arg RUNNER_ENVIRONMENT=public \
  --build-arg MESH_LLM_REVISION="$(git -C /Users/ndizazzo/dev/mesh/mesh-llm rev-parse HEAD)" \
  --build-arg RUNNER_IMAGES_REVISION="$(git rev-parse HEAD)" \
  --load \
  -t mesh-llm-runner:public .

docker run --rm --entrypoint verify-runner-image mesh-llm-runner:public public cpu
```

Use target `self-hosted` and `RUNNER_ENVIRONMENT=self-hosted` for an image that includes the GitHub Actions runner. Select `BACKEND=cpu|vulkan|cuda|rocm|web`; CUDA additionally accepts `CUDA_SERIES`, while ROCm accepts `ROCM_VERSION` and currently requires AMD64. For lean images, select `--file Dockerfile.ui`, `--platform linux/amd64`, `--target public-test`, and `BACKEND=ui` or `BACKEND=browser`.

## Maintenance pipeline

`.github/workflows/build-and-push.yml` runs on pull requests, pushes to `main`, a weekly schedule, and manual dispatch. It:

1. validates the workflow and immutable-candidate contract before expensive work;
2. checks out the requested MeshLLM ref and generates both manifest bundles;
3. builds affected pull-request families plus one always-on public CPU AMD64 contract row, while trusted main and scheduled runs remain exhaustive;
4. verifies each trusted staged image through its exact registry digest, then assembles and validates one immutable index descriptor per family;
5. promotes timestamp, MeshLLM compatibility, and digest-derived immutable tags from those descriptors without rebuilding;
6. records the complete previous/target `latest` map, then reconciles the eventual `latest` cohort from that retained manifest.

Execution is explicit: `validate` builds test targets without registry writes, `stage` pushes and verifies run-scoped candidates without moving production aliases, and `promote` performs the same staging before versioned and eventual-`latest` reconciliation. Manual dispatch defaults to `validate`; any staging or promotion requires the exact repository, `refs/heads/main`, and the default-branch caller workflow. Main pushes stage candidates, while the weekly schedule performs the deliberate production promotion.

Pull requests receive no package-write permission and run only affected
families plus the public CPU AMD64 contract row. Every platform build uses
Depot remote BuildKit and its persistent project-scoped cache; no job imports
or exports `type=gha` cache archives. Public fork builds are isolated from the
project cache by Depot. Trusted staging and promotion push immutable platform
digests directly from the remote builder to GHCR, while GHCR remains the
canonical registry. The checked-in Depot project configuration and required
OIDC trust setup are documented in `docs/OPERATIONS.md`.

Supported environments, backends, architectures, Dockerfile choices, compatibility aliases, and extra indexes are declared in `config/runner-image-families.json`; `scripts/generate-workflow-matrices.sh` validates that descriptor and generates both build and promotion matrices. The 15 families cover 23 platform rows and produce 16 promotion indexes, including the existing mixed self-hosted index. Validation and staging check each requested build against this catalog before selecting its Dockerfile.

Pull requests always use native GitHub-hosted `ubuntu-24.04` and `ubuntu-24.04-arm` runners. The policy job is also fixed to GitHub-hosted Ubuntu and selects the downstream provider. The called family workflow independently derives literal runner labels and permits Depot only for the exact repository, default-branch caller workflow, `refs/heads/main`, a trusted event, and `DEPOT_RUNNERS_ENABLED=true`. It accepts no caller-provided runner JSON. All mismatches fall back to GitHub-hosted labels or fail before checkout.

The weekly default-branch publication is intentionally Depot-eligible when that gate is enabled: it is a trusted, high-value full image rebuild. Scheduled runs on any other ref remain GitHub-hosted.

The runner gate is independent of container builds: GitHub-hosted pull-request
runners still dispatch Docker builds to Depot. Depot isolates public fork
builds from the project cache, while authorized same-repository builds share
the persistent content-addressed cache.

Published tags are:

- `<environment>-<backend>-latest`
- `<environment>-<backend>-YYYYMMDDHHMMSS` for discovery and evaluation
- `<environment>-<backend>-sha-<12-character MeshLLM revision>` is a mutable compatibility alias and may move when runner-image inputs change
- `<environment>-<backend>-digest-sha256-<64-hex manifest digest>` is the collision-proof immutable content identity and refuses conflicting overwrite

MeshLLM and runner-images source revisions remain full OCI labels and candidate-descriptor fields. They are not used as immutable tag identity because provenance timestamps and resolved package inputs can legitimately change content for the same source pair. Production consumers resolve a selected tag and pin its immutable manifest digest; tags are not the production contract.

## Consumers

- `examples/workflows/public-github-hosted.yml` runs on `ubuntu-24.04` with the public image through job-level `container:`.
- `scripts/verify-end-to-end.sh` verifies the registry manifest lists and executes every supported architecture.

Run `bash scripts/test.sh` with Bash 4 or newer for the complete local contract
suite. CI uses the same entrypoint and automatically includes every
`tests/*.test.sh` suite. These tests use temporary fixtures and a mock registry.
`scripts/verify-end-to-end.sh --all-backends` checks every catalog family,
including public web, UI and browser, against its declared capabilities and versions.

For a locally built full image, `bash tests/integration/dependency-cache.sh IMAGE`
checks offline npm and pnpm installation as root and runner with Actions' home
directory. It uses fresh containers with networking disabled and no host cache
mounts. These Docker integration checks are opt-in and separate from the host
contract suite.

After preparing manifest bundles, run
`bash tests/integration/layer-cache.sh . --with-vulkan` to check source-only
reuse, dependency invalidation, and shared dependency layers across Vulkan and
CPU. It retains local images, fixture context, build logs, and parsed evidence.
`--evidence-only PROOF_DIRECTORY` rechecks those logs and local image identities
without rebuilding. Layer identity is measured with filesystem diffIDs; it does
not report compressed registry bytes or infer time saved.

`bash tests/integration/runner-installation.sh SELF_HOSTED_IMAGE EXPECTED_VERSION`
checks the inherited runner installation, both Node convention paths, and the
actual self-hosted entrypoint with networking disabled.

`bash tests/integration/python-lock.sh IMAGE` verifies that the image contains
the checked-in lock and exactly its runtime packages, then runs `pip check`
with networking disabled. Run it on both architectures when refreshing the lock.

See `docs/AUDIT.md` for the source audit and `docs/OPERATIONS.md` for publication and registry-verification steps.

See [runner image identity](docs/RUNNER_IDENTITY.md) for verified tool and
dependency receipts, OCI digest binding, cache compatibility limits, and the
opt-in offline identity check.
