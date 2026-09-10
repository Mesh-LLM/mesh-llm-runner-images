# syntax=docker/dockerfile:1.7

ARG BACKEND=cpu
ARG ACTIONS_RUNNER_BASE_IMAGE=ghcr.io/actions/actions-runner:latest@sha256:0cfdcc701ce933c6d243c6b0b2da767366dc9f2e99961d4c3754b0b78084cdda

# Base image = official GitHub Actions runner image. Pinned by digest;
# the digest corresponds to the upstream `latest` tag at the time of this
# commit. It provides:
#   - Ubuntu 24.04 (noble), ImageOS=ubuntu24,
#   - runner user (uid 1001, gid 1001), supplementary groups: sudo, users, docker (gid 123),
#   - actions/runner externals at /home/runner/externals/{node20,node24}/bin/{node,npm,npx,corepack}
#     (node24 = v24.18.0, node20 = v20.20.2),
#   - /usr/bin/docker (client only, no dockerd),
#   - ENV: RUNNER_MANUALLY_TRAP_SIG=1, ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT=1, ImageOS=ubuntu24,
#   - ENTRYPOINT=[], CMD=[/bin/bash], WORKDIR=/home/runner.
# Known-good reference digest (mirrors `latest` as of July 2026):
#   sha256:0cfdcc701ce933c6d243c6b0b2da767366dc9f2e99961d4c3754b0b78084cdda
FROM ${ACTIONS_RUNNER_BASE_IMAGE} AS toolchain

ARG TARGETARCH

LABEL org.opencontainers.image.source="https://github.com/Mesh-LLM/mesh-llm-runner-images" \
      org.opencontainers.image.description="Reproducible multi-architecture MeshLLM CI environment" \
      org.opencontainers.image.licenses="MIT" \
      io.mesh-llm.runner.gha-convention="true"

# Note: ImageOS, ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT, and
# RUNNER_MANUALLY_TRAP_SIG are inherited from the base image's ENV and
# are intentionally NOT re-declared here.
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    CARGO_HOME=/home/runner/.cargo \
    RUSTUP_HOME=/home/runner/.rustup \
    PNPM_HOME=/home/runner/.local/share/pnpm \
    VIRTUAL_ENV=/opt/mesh-llm/venv \
    PATH=/home/runner/externals/node24/bin:/opt/mesh-llm/venv/bin:/home/runner/.local/share/pnpm:/home/runner/.cargo/bin:${PATH} \
    CARGO_INCREMENTAL=0 \
    CARGO_NET_RETRY=10 \
    CARGO_HTTP_MULTIPLEXING=false

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# The base image sets USER=runner; all subsequent RUN/COPY need root, so
# switch back to root here. The trailing `USER runner` at the end of this
# stage restores the runner context for downstream stages that inherit
# from `toolchain` without an explicit USER switch (e.g. backend-cpu).
USER root

COPY profiles/common.yml /tmp/profiles/common.yml
COPY scripts/profile-packages.sh /usr/local/bin/profile-packages
RUN --mount=type=cache,id=mesh-runner-apt-lists-ubuntu24-${TARGETARCH},target=/var/lib/apt/lists,sharing=locked \
    --mount=type=cache,id=mesh-runner-apt-archives-ubuntu24-${TARGETARCH},target=/var/cache/apt,sharing=locked \
    chmod 0755 /usr/local/bin/profile-packages \
    && rm -f /etc/apt/apt.conf.d/docker-clean \
    && profile-packages /tmp/profiles/common.yml > /tmp/profiles/packages.txt \
    && mapfile -t packages < /tmp/profiles/packages.txt \
    && test "${#packages[@]}" -gt 0 \
    && apt-get update \
    && apt-get install -y --no-install-recommends software-properties-common \
    && add-apt-repository -y universe \
    && apt-get update \
    && apt-get install -y --no-install-recommends "${packages[@]}" \
    && rm -rf /tmp/profiles

# The base image already provides:
#   - group `docker` (gid 123), runner user (uid 1001) with supplementary
#     groups [sudo, users, docker] and /home/runner (mode 0777, owned by
#     runner:runner).
#   - /usr/bin/docker CLI (client only).
#   - /etc/sudoers granting `%sudo ALL=(ALL:ALL) NOPASSWD:ALL` (no `root`
#     entry, no @includedir /etc/sudoers.d directive). For this reason
#     install-core-tools.sh and warm-dependencies.sh use `runuser -u
#     runner --` (util-linux) instead of `sudo -u runner` for the
#     root→runner user transitions during image build.
# Only the /opt/mesh-llm workdir needs to be created on top of the base.
RUN mkdir -p \
      /opt/mesh-llm \
      /home/runner/.cargo \
      /home/runner/.local/share/pnpm \
      /home/runner/.rustup/downloads \
    && chown -R runner:docker /opt/mesh-llm /home/runner

ARG NODE_MAJOR=24
ARG PNPM_VERSION=10.34.5
ARG RUST_VERSION=1.98.1
ARG JUST_VERSION=1.57.0
ARG SCCACHE_VERSION=0.16.0
ARG OPENAI_NPM_VERSION=7.5.0
COPY scripts/install-tools-common.sh /usr/local/bin/install-tools-common.sh
COPY scripts/install-core-tools.sh /usr/local/bin/install-core-tools
RUN --mount=type=cache,id=mesh-runner-npm-node${NODE_MAJOR}-ubuntu24-${TARGETARCH},target=/root/.npm,sharing=locked \
    --mount=type=cache,id=mesh-runner-rustup-${RUST_VERSION}-ubuntu24-${TARGETARCH},target=/home/runner/.rustup/downloads,uid=1001,gid=123,mode=0775,sharing=locked \
    --mount=type=cache,id=mesh-runner-tool-downloads-ubuntu24-${TARGETARCH},target=/var/cache/mesh-downloads,sharing=locked \
    chmod 0755 /usr/local/bin/install-core-tools \
    && TARGETARCH="${TARGETARCH}" NODE_MAJOR="${NODE_MAJOR}" JUST_VERSION="${JUST_VERSION}" SCCACHE_VERSION="${SCCACHE_VERSION}" \
       OPENAI_NPM_VERSION="${OPENAI_NPM_VERSION}" PNPM_VERSION="${PNPM_VERSION}" RUST_VERSION="${RUST_VERSION}" \
       /usr/local/bin/install-core-tools

RUN git lfs install --system

WORKDIR /workspace
USER runner

# Resolve dependencies once per architecture, independently of SDK installation.
# Final images copy these stores in independent layers after selecting an SDK.
FROM toolchain AS dependencies
USER root
ARG TARGETARCH
ENV NPM_CONFIG_CACHE=/home/runner/.npm \
    npm_config_store_dir=/home/runner/.local/share/pnpm/store
# Both environments have the same payload; provenance is copied separately.
COPY build-context/manifests/public/dependencies/ /opt/mesh-llm/manifests/
COPY config/python-requirements.lock /etc/mesh-runner-python-requirements.lock
COPY scripts/warm-dependencies.sh /usr/local/bin/warm-dependencies
COPY scripts/verify-python-requirements.sh /usr/local/bin/verify-python-requirements
RUN --mount=type=cache,id=mesh-runner-pip-python3.12-ubuntu24-${TARGETARCH},target=/root/.cache/pip,sharing=locked \
    chmod 0755 /usr/local/bin/warm-dependencies /usr/local/bin/verify-python-requirements \
    && mkdir -p /home/runner/.cargo/git /home/runner/.cargo/registry \
    && chown -R runner:docker /opt/mesh-llm/manifests /home/runner/.cargo \
    && /usr/local/bin/warm-dependencies /opt/mesh-llm/manifests

FROM toolchain AS backend-cpu

FROM toolchain AS backend-vulkan

# NVIDIA Container Toolkit defaults to compute,utility. Graphics is additionally
# required for it to inject the Vulkan ICD and driver libraries.
USER root
COPY scripts/verify-vulkan-device.sh /usr/local/bin/verify-vulkan-device
RUN chmod 0755 /usr/local/bin/verify-vulkan-device
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility,graphics
USER runner

FROM toolchain AS backend-cuda

USER root
ARG TARGETARCH
ARG INSTALL_CUDA=1
ARG CUDA_SERIES=12-9
COPY scripts/install-cuda-toolchain.sh /usr/local/bin/install-cuda-toolchain
COPY scripts/verify-vulkan-device.sh /usr/local/bin/verify-vulkan-device
RUN --mount=type=cache,id=mesh-runner-apt-lists-ubuntu24-cuda${CUDA_SERIES}-${TARGETARCH},target=/var/lib/apt/lists,sharing=locked \
    --mount=type=cache,id=mesh-runner-apt-archives-ubuntu24-cuda${CUDA_SERIES}-${TARGETARCH},target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=mesh-runner-tool-downloads-ubuntu24-${TARGETARCH},target=/var/cache/mesh-downloads,sharing=locked \
    chmod 0755 /usr/local/bin/install-cuda-toolchain /usr/local/bin/verify-vulkan-device \
    && TARGETARCH="${TARGETARCH}" INSTALL_CUDA="${INSTALL_CUDA}" CUDA_SERIES="${CUDA_SERIES}" \
       /usr/local/bin/install-cuda-toolchain
ENV CUDA_HOME=/usr/local/cuda \
    PATH=/usr/local/cuda/bin:${PATH} \
    LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64 \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility,graphics
USER runner

FROM toolchain AS backend-rocm

USER root
ARG TARGETARCH
ARG INSTALL_ROCM=1
ARG ROCM_VERSION=7.2.3
COPY scripts/install-rocm-toolchain.sh /usr/local/bin/install-rocm-toolchain
RUN --mount=type=cache,id=mesh-runner-apt-lists-ubuntu24-rocm${ROCM_VERSION}-${TARGETARCH},target=/var/lib/apt/lists,sharing=locked \
    --mount=type=cache,id=mesh-runner-apt-archives-ubuntu24-rocm${ROCM_VERSION}-${TARGETARCH},target=/var/cache/apt,sharing=locked \
    chmod 0755 /usr/local/bin/install-rocm-toolchain \
    && TARGETARCH="${TARGETARCH}" INSTALL_ROCM="${INSTALL_ROCM}" ROCM_VERSION="${ROCM_VERSION}" \
       /usr/local/bin/install-rocm-toolchain
ENV ROCM_PATH=/opt/rocm \
    PATH=/opt/rocm/bin:${PATH} \
    LD_LIBRARY_PATH=/opt/rocm/lib
USER runner

FROM toolchain AS backend-web

# Chromium's system dependencies are Playwright's to own, not ours: rather
# than hand-listing them in profiles/backends/web.yml (which stays an empty
# apt.packages list, like cpu.yml), `playwright install-deps chromium`
# derives and installs that list itself at build time. The version baked
# here is the single declared pin in config/playwright-pin.txt; mesh-llm's
# ui_e2e job asserts its own @playwright/test resolves to the same string
# before it trusts this image (see docs/OPERATIONS.md).
USER root
ARG TARGETARCH
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
    NODE_PATH=/home/runner/externals/node24/lib/node_modules
COPY config/playwright-pin.txt /tmp/playwright-pin.txt
# Share installation and installed-version validation with the lean browser image.
COPY scripts/install-playwright.sh /usr/local/bin/install-playwright
RUN --mount=type=cache,id=mesh-runner-apt-lists-ubuntu24-web-${TARGETARCH},target=/var/lib/apt/lists,sharing=locked \
    --mount=type=cache,id=mesh-runner-apt-archives-ubuntu24-web-${TARGETARCH},target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=mesh-runner-npm-node${NODE_MAJOR}-ubuntu24-web-${TARGETARCH},target=/root/.npm,sharing=locked \
    chmod 0755 /usr/local/bin/install-playwright \
    && /usr/local/bin/install-playwright /tmp/playwright-pin.txt \
    && rm -f /tmp/playwright-pin.txt
USER runner

ARG BACKEND
FROM backend-${BACKEND} AS selected-backend

ARG BACKEND
ARG CUDA_SERIES=none
ARG ROCM_VERSION=none
ARG TARGETARCH
USER root
COPY profiles/backends/${BACKEND}.yml /tmp/profiles/backend.yml
RUN --mount=type=cache,id=mesh-runner-apt-lists-ubuntu24-${BACKEND}-${CUDA_SERIES}-${ROCM_VERSION}-${TARGETARCH},target=/var/lib/apt/lists,sharing=locked \
    --mount=type=cache,id=mesh-runner-apt-archives-ubuntu24-${BACKEND}-${CUDA_SERIES}-${ROCM_VERSION}-${TARGETARCH},target=/var/cache/apt,sharing=locked \
    profile-packages /tmp/profiles/backend.yml > /tmp/profiles/backend-packages.txt \
    && mapfile -t packages < /tmp/profiles/backend-packages.txt \
    && if (( ${#packages[@]} > 0 )); then \
          apt-get update; \
          apt-get install -y --no-install-recommends "${packages[@]}"; \
        fi \
    && rm -f /tmp/profiles/backend.yml /tmp/profiles/backend-packages.txt \
    && printf '%s\n' "${BACKEND}" > /etc/mesh-runner-backend \
    && printf '%s\n' "${CUDA_SERIES}" > /etc/mesh-runner-cuda-series \
    && printf '%s\n' "${ROCM_VERSION}" > /etc/mesh-runner-rocm-version
ENV MESH_RUNNER_BACKEND=${BACKEND}

# Link layers independently of the SDK snapshot so every backend shares the
# same dependency content. A lockfile change cannot rerun SDK installation.
ENV NPM_CONFIG_CACHE=/home/runner/.npm \
    npm_config_store_dir=/home/runner/.local/share/pnpm/store
COPY --link --chown=1001:123 --from=dependencies /opt/mesh-llm/ /opt/mesh-llm/
COPY --link --chown=1001:123 --from=dependencies /home/runner/.cargo/registry/ /home/runner/.cargo/registry/
COPY --link --chown=1001:123 --from=dependencies /home/runner/.cargo/git/ /home/runner/.cargo/git/
COPY --link --chown=1001:123 --from=dependencies /home/runner/.npm/ /home/runner/.npm/
COPY --link --chown=1001:123 --from=dependencies /home/runner/.local/share/pnpm/store/ /home/runner/.local/share/pnpm/store/

ARG RUNNER_ENVIRONMENT=public
COPY profiles/${RUNNER_ENVIRONMENT}.yml /tmp/profiles/environment.yml
RUN --mount=type=cache,id=mesh-runner-apt-lists-ubuntu24-${TARGETARCH},target=/var/lib/apt/lists,sharing=locked \
    --mount=type=cache,id=mesh-runner-apt-archives-ubuntu24-${TARGETARCH},target=/var/cache/apt,sharing=locked \
    profile-packages /tmp/profiles/environment.yml > /tmp/profiles/packages.txt \
    && mapfile -t packages < /tmp/profiles/packages.txt \
    && if (( ${#packages[@]} > 0 )); then \
         apt-get update; \
         apt-get install -y --no-install-recommends "${packages[@]}"; \
       fi \
    && rm -rf /tmp/profiles

COPY build-context/manifests/${RUNNER_ENVIRONMENT}/manifest-index.json \
     build-context/manifests/${RUNNER_ENVIRONMENT}/source-revision.txt \
     build-context/manifests/${RUNNER_ENVIRONMENT}/profile.txt /opt/mesh-llm/manifests/
LABEL io.mesh-llm.runner.environment="${RUNNER_ENVIRONMENT}"
COPY config/python-requirements.lock /etc/mesh-runner-python-requirements.lock
COPY scripts/verify-runner-image.sh /usr/local/bin/verify-runner-image
RUN chmod 0755 /usr/local/bin/verify-runner-image
USER runner

FROM selected-backend AS public
USER root
ARG MESH_LLM_REVISION=unknown
ARG RUNNER_IMAGES_REVISION=unknown
ENV MESH_RUNNER_ENVIRONMENT=public
LABEL io.mesh-llm.source.revision="${MESH_LLM_REVISION}" \
      io.mesh-llm.runner-images.revision="${RUNNER_IMAGES_REVISION}"
RUN printf '%s\n' public > /etc/mesh-runner-environment \
    && printf '%s\n' "${MESH_LLM_REVISION}" > /etc/mesh-llm-revision \
    && printf '%s\n' "${RUNNER_IMAGES_REVISION}" > /etc/mesh-runner-images-revision
# GHA convention paths. When this image is used as a workflow `container:`
# image via DinD (host docker socket mounted on the ARC runner pod, no
# kubelet bind-mount of /__e), /__e/node24/bin/node must resolve in-image.
# The symlinks point at the actions/runner-bundled externals so the path
# works in both ARC-hosted (kubelet bind-mounts /__e, masking the symlink
# - harmless) and DinD (symlink resolves) execution modes.
RUN mkdir -p /__e /__w /github/home /github/workflow \
    && ln -s /home/runner/externals/node24 /__e/node24 \
    && ln -s /home/runner/externals/node20 /__e/node20 \
    && chmod 0777 /__w /github/home /github/workflow
ENTRYPOINT []
CMD ["/bin/bash"]

FROM public AS public-test
ARG BACKEND
ARG MESH_LLM_REVISION
ARG RUNNER_IMAGES_REVISION
ARG VERIFIER_REVISION
ARG CUDA_SERIES=none
ARG ROCM_VERSION=none
COPY config/playwright-pin.txt config/tool-pins.json config/cache-policy.json config/python-requirements.lock /opt/mesh-runner-verification/
COPY scripts/verify-runner-candidate.sh scripts/verify-runner-image.sh scripts/collect-runner-identity.py /opt/mesh-runner-verification/
RUN --network=none expected_playwright=none \
    && if [[ "${BACKEND}" == web ]]; then expected_playwright="$(cat /opt/mesh-runner-verification/playwright-pin.txt)"; fi \
    && bash /opt/mesh-runner-verification/verify-runner-candidate.sh \
      --expected-directory /opt/mesh-runner-verification \
      --verifier-revision "${VERIFIER_REVISION}" \
      public \
      "${BACKEND}" \
      "${MESH_LLM_REVISION}" \
      "${CUDA_SERIES}" \
      "${ROCM_VERSION}" \
      "${RUNNER_IMAGES_REVISION}" \
      "$expected_playwright" > /tmp/mesh-runner-identity.json \
    && cat /tmp/mesh-runner-identity.json

FROM selected-backend AS self-hosted

USER root
ARG MESH_LLM_REVISION=unknown
ARG RUNNER_IMAGES_REVISION=unknown
# The digest-pinned base already contains the complete Actions runner and its
# Node runtimes. Preserve that installation instead of overlaying a second copy.

# GHA convention paths (same rationale as the `public` target). At runtime
# the ARC runner pod's kubelet may bind-mount /__e over the symlink; that
# overwrites the in-image symlink, which is harmless.
RUN mkdir -p /__e /__w /github/home /github/workflow \
    && ln -s /home/runner/externals/node24 /__e/node24 \
    && ln -s /home/runner/externals/node20 /__e/node20 \
    && chmod 0777 /__w /github/home /github/workflow

# RUNNER_MANUALLY_TRAP_SIG and ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT are
# inherited from the base image's ENV and are intentionally NOT re-declared here.
ENV MESH_RUNNER_ENVIRONMENT=self-hosted
LABEL io.mesh-llm.source.revision="${MESH_LLM_REVISION}" \
      io.mesh-llm.runner-images.revision="${RUNNER_IMAGES_REVISION}"
RUN printf '%s\n' self-hosted > /etc/mesh-runner-environment \
    && printf '%s\n' "${MESH_LLM_REVISION}" > /etc/mesh-llm-revision \
    && printf '%s\n' "${RUNNER_IMAGES_REVISION}" > /etc/mesh-runner-images-revision

WORKDIR /home/runner
USER runner
ENTRYPOINT ["/home/runner/run.sh"]

FROM self-hosted AS self-hosted-test
ARG BACKEND
ARG MESH_LLM_REVISION
ARG RUNNER_IMAGES_REVISION
ARG VERIFIER_REVISION
ARG CUDA_SERIES=none
ARG ROCM_VERSION=none
COPY config/playwright-pin.txt config/tool-pins.json config/cache-policy.json config/python-requirements.lock /opt/mesh-runner-verification/
COPY scripts/verify-runner-candidate.sh scripts/verify-runner-image.sh scripts/collect-runner-identity.py /opt/mesh-runner-verification/
RUN --network=none bash /opt/mesh-runner-verification/verify-runner-candidate.sh \
      --expected-directory /opt/mesh-runner-verification \
      --verifier-revision "${VERIFIER_REVISION}" \
      self-hosted \
      "${BACKEND}" \
      "${MESH_LLM_REVISION}" \
      "${CUDA_SERIES}" \
      "${ROCM_VERSION}" \
      "${RUNNER_IMAGES_REVISION}" \
      none > /tmp/mesh-runner-identity.json \
    && cat /tmp/mesh-runner-identity.json
