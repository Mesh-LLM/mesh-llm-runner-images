# MeshLLM runner images

This repository builds one multi-architecture MeshLLM CI image package with two tags derived from the same core toolchain:

- `ghcr.io/mesh-llm/mesh-llm-cuda-runner:public-latest` — used as a GitHub-hosted job container.
- `ghcr.io/mesh-llm/mesh-llm-cuda-runner:self-hosted-latest` — used by Actions Runner Controller (ARC) runner pods.

Both tags support `linux/amd64` and `linux/arm64`. The self-hosted AMD64 image also contains CUDA 12.9; the ARM64 image deliberately omits CUDA because the K3s ARM pools are CPU builders. The existing GHCR package name is retained to avoid a registry and credential migration.

## Design

The image has three layers of configuration:

1. `profiles/common.yml` is the shared operating-system toolchain found in MeshLLM CI and build scripts.
2. `profiles/public.yml` and `profiles/self-hosted.yml` contain environment-only additions.
3. `scripts/prepare-build-context.sh` checks out the requested MeshLLM revision, discovers its Rust, Node, Python, and Go manifests, and creates one bundle per runner environment. The Docker build injects the matching bundle and warms Cargo, pnpm, npm, and Python dependencies.

The YAML profiles use a deliberately small schema (`schema`, `profile`, and `apt.packages`) that is parsed by portable Bash without Python or Ruby. The manifest bundle is content-addressed in `manifest-index.json`. Cargo target stubs retain the complete workspace graph without copying or publishing MeshLLM source code in the runner image.

## Local build

```bash
scripts/prepare-build-context.sh /Users/ndizazzo/dev/mesh/mesh-llm

docker buildx build \
  --platform linux/amd64 \
  --target public \
  --build-arg RUNNER_ENVIRONMENT=public \
  --build-arg MESH_LLM_REVISION="$(git -C /Users/ndizazzo/dev/mesh/mesh-llm rev-parse HEAD)" \
  --load \
  -t mesh-llm-runner:public .

docker run --rm --entrypoint verify-runner-image mesh-llm-runner:public public
```

Use target `self-hosted` and `RUNNER_ENVIRONMENT=self-hosted` for the ARC image. Set `INSTALL_CUDA=0` only for a local fast build; published self-hosted AMD64 images always install CUDA.

## Maintenance pipeline

`.github/workflows/build-and-push.yml` runs on pull requests, pushes to `main`, a weekly schedule, and manual dispatch. It:

1. checks out the requested MeshLLM ref;
2. generates and uploads both manifest bundles;
3. builds and executes each environment on AMD64 and ARM64;
4. publishes multi-platform tags, SBOMs, provenance, and GitHub attestations to GHCR.

Published tags are:

- `<environment>-latest`
- `<environment>-YYYYMMDDHHMMSS` for Flux image automation
- `<environment>-sha-<MeshLLM revision>` for source traceability

## Consumers

- `examples/workflows/public-github-hosted.yml` runs on `ubuntu-24.04` with the public image through job-level `container:`.
- `examples/workflows/k3s-self-hosted.yml` targets the `mesh-llm-amd64` and `mesh-llm-arm64` ARC scale sets. It does not add another job container: the ephemeral ARC pod is already the self-hosted image.
- `scripts/verify-end-to-end.sh` verifies the registry manifest lists and executes both architectures. Add `--cluster` to reconcile Flux and inspect ARC resources.

See `docs/AUDIT.md` for the source audit and `docs/OPERATIONS.md` for rollout and acceptance steps.
