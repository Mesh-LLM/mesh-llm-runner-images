# mesh-llm-runner-images

Build and publish sources for the Mesh-LLM self-hosted runner images.

## Published image

- `ghcr.io/mesh-llm/mesh-llm-cuda-runner:v3`

## Runner base

- GitHub Actions runner: `2.334.0` via `myoung34/github-runner:2.334.0-ubuntu-jammy`

## Repository layout

- `Dockerfile` - CUDA-capable runner image based on `myoung34/github-runner`
- `scripts/install-cuda-toolchain.sh` - installs CUDA toolkit and build dependencies
- `.github/workflows/` - CI and publish workflows for this image repo

## Workflows

- `Build Test` - validates the image builds on pull requests and manual dispatch
- `Publish GHCR` - publishes `ghcr.io/mesh-llm/mesh-llm-cuda-runner`

## Manual workflow inputs

- `Publish GHCR`
  - `image_tag` (default `v3`)

The workflow path is now the supported way to build and publish the image.

## Carrack runner upgrade runbook

GitHub warned that older self-hosted runner versions will soon be unsupported. Upgrade Carrack outside any active release validation window before depending on it for production release validation.

1. Drain Carrack: confirm no release validation or long GPU/CPU jobs are running.
2. From the Carrack runner service directory, stop the service:

   ```bash
   sudo ./svc.sh stop
   ```

3. Apply the latest supported Linux x64 GitHub Actions runner package from the official `actions/runner` release page. Do not rerun `config.sh` or mint a registration token unless the runner must be re-registered.
4. Restart and check the service:

   ```bash
   sudo ./svc.sh start
   sudo ./svc.sh status
   ```

5. In GitHub, confirm the Carrack runner reports all labels targeted by `runner=carrack` workflows:
   - `self-hosted`
   - `Linux`
   - `X64`
6. Run a cheap Carrack smoke slice first.
7. Repeat one known green phased row, such as `ubuntu-cpu-amd64` or `alpine-cpu-amd64`, before relying on Carrack for longer GPU/CPU validation.
