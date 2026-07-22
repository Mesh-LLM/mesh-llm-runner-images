# MeshLLM CI and build audit

Audit date: 2026-07-22. Source branch: `Mesh-LLM/mesh-llm@main` at `88f8b95b74e8de523b49d9307e22dac115178eea`.

## Evidence reviewed

- Root `Justfile`, `Cargo.toml`, `Cargo.lock`, `.nvmrc`, build scripts, Dockerfiles, and all GitHub Actions workflows.
- Main CI run [29918244889](https://github.com/Mesh-LLM/mesh-llm/actions/runs/29918244889), which completed successfully across Linux CPU/CUDA/ROCm and Windows jobs.
- PR Builds run [29933383305](https://github.com/Mesh-LLM/mesh-llm/actions/runs/29933383305), which completed successfully across Linux CPU/CUDA/ROCm/Vulkan, macOS, and Windows jobs.
- Nightly Stability run [29915686296](https://github.com/Mesh-LLM/mesh-llm/actions/runs/29915686296). Its failures were remote inference behavior, timeouts, rate limiting, and tool-call reliability; environment setup completed successfully.

## Manifest inventory

The generated inventory is authoritative for each image build. At the audited revision it contains:

- Rust: the root `Cargo.toml` and `Cargo.lock`, plus every workspace member manifest under `crates/` and `tools/xtask/Cargo.toml`.
- Node/UI: `crates/mesh-llm-ui/package.json`, `package-lock.json`, and `pnpm-lock.yaml`.
- Node/website: `website/package.json` and `website/package-lock.json`.
- Node SDK: `sdk/node/package.json`.
- Python CI: `ci/requirements-ci-python.txt` (`langchain-openai`, `litellm`, and `openai`).
- Go: none found.
- Toolchain selectors: `.nvmrc` (Node 24) and Cargo workspace edition 2024.

Do not maintain this list by hand in the Dockerfile. `scripts/collect-manifests.sh` uses Bash, `cargo metadata`, and `jq` for Rust, then walks the repository for supported package-manager filenames. It needs no Python or Ruby runtime. Every collected manifest and SHA-256 is written to `manifest-index.json`.

## Repeated Linux environment requirements

The workflows repeatedly install these groups:

- Rust stable with `rustfmt` and `clippy`, plus the Android ARM64 target used by the main Linux artifact job.
- Node 24, npm, and pnpm.
- C/C++ build chain: `build-essential`, CMake, Ninja, pkg-config, LLD, and sccache.
- System libraries: OpenSSL, D-Bus, curl, and standard packaging utilities.
- Vulkan compilation: `glslc`, `libvulkan-dev`, and `spirv-headers`.
- CI/diagnostics: Python 3 with venv/pip, curl, git/LFS, jq, lsof, patchelf, rsync, and shellcheck.
- GPU specializations: CUDA for the NVIDIA/x64 runner. ROCm remains a workload-specific container concern because the current K3s self-hosted x64 node is NVIDIA, not AMD.

## Environment policy

The public and self-hosted variants intentionally receive the same project manifest inventory and common toolchain. Only operational packages and hardware SDKs differ:

| Capability | Public | Self-hosted ARM64 | Self-hosted AMD64 |
| --- | --- | --- | --- |
| Core Linux/Rust/Node/Python/Vulkan tools | yes | yes | yes |
| Project manifest/dependency cache | yes | yes | yes |
| GitHub runner binary | no | yes | yes |
| Cluster diagnostics | no | yes | yes |
| CUDA build toolkit | no | no | yes |

This avoids claiming false parity between CPU ARM nodes and an NVIDIA node while keeping their base compiler and package environment identical.
