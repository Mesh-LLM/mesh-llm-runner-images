# syntax=docker/dockerfile:1.7

ARG BACKEND=cpu

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
FROM ghcr.io/actions/actions-runner:latest@sha256:0cfdcc701ce933c6d243c6b0b2da767366dc9f2e99961d4c3754b0b78084cdda AS toolchain

ARG TARGETARCH
ARG RUNNER_ENVIRONMENT=public
ARG MESH_LLM_REVISION=unknown
ARG NODE_MAJOR=24
ARG JUST_VERSION=1.57.0
ARG SCCACHE_VERSION=0.16.0

LABEL org.opencontainers.image.source="https://github.com/Mesh-LLM/mesh-llm-runner-images" \
      org.opencontainers.image.description="Reproducible multi-architecture MeshLLM CI environment" \
      org.opencontainers.image.licenses="MIT" \
      io.mesh-llm.runner.environment="${RUNNER_ENVIRONMENT}" \
      io.mesh-llm.source.revision="${MESH_LLM_REVISION}" \
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
COPY profiles/${RUNNER_ENVIRONMENT}.yml /tmp/profiles/environment.yml
COPY scripts/profile-packages.sh /usr/local/bin/profile-packages
RUN chmod 0755 /usr/local/bin/profile-packages \
    && mapfile -t packages < <(profile-packages /tmp/profiles/common.yml /tmp/profiles/environment.yml) \
    && test "${#packages[@]}" -gt 0 \
    && apt-get update \
    && apt-get install -y --no-install-recommends software-properties-common \
    && add-apt-repository -y universe \
    && apt-get update \
    && apt-get install -y --no-install-recommends "${packages[@]}" \
    && rm -rf /tmp/profiles \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

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
RUN mkdir -p /opt/mesh-llm \
    && chown -R runner:docker /opt/mesh-llm /home/runner

COPY scripts/install-core-tools.sh /usr/local/bin/install-core-tools
RUN chmod 0755 /usr/local/bin/install-core-tools \
    && TARGETARCH="${TARGETARCH}" NODE_MAJOR="${NODE_MAJOR}" JUST_VERSION="${JUST_VERSION}" SCCACHE_VERSION="${SCCACHE_VERSION}" \
       /usr/local/bin/install-core-tools

COPY build-context/manifests/${RUNNER_ENVIRONMENT}/ /opt/mesh-llm/manifests/
COPY scripts/warm-dependencies.sh /usr/local/bin/warm-dependencies
RUN chmod 0755 /usr/local/bin/warm-dependencies \
    && chown -R runner:docker /opt/mesh-llm/manifests \
    && /usr/local/bin/warm-dependencies /opt/mesh-llm/manifests

COPY scripts/verify-runner-image.sh /usr/local/bin/verify-runner-image
RUN chmod 0755 /usr/local/bin/verify-runner-image \
    && printf '%s\n' "${RUNNER_ENVIRONMENT}" > /etc/mesh-runner-environment \
    && printf '%s\n' "${MESH_LLM_REVISION}" > /etc/mesh-llm-revision \
    && git lfs install --system

WORKDIR /workspace
USER runner

FROM toolchain AS backend-cpu

FROM toolchain AS backend-vulkan

FROM toolchain AS backend-cuda

USER root
ARG TARGETARCH
ARG INSTALL_CUDA=1
ARG CUDA_SERIES=12-9
COPY scripts/install-cuda-toolchain.sh /usr/local/bin/install-cuda-toolchain
RUN chmod 0755 /usr/local/bin/install-cuda-toolchain \
    && TARGETARCH="${TARGETARCH}" INSTALL_CUDA="${INSTALL_CUDA}" CUDA_SERIES="${CUDA_SERIES}" \
       /usr/local/bin/install-cuda-toolchain
ENV CUDA_HOME=/usr/local/cuda \
    PATH=/usr/local/cuda/bin:${PATH} \
    LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64
USER runner

FROM toolchain AS backend-rocm

USER root
ARG TARGETARCH
ARG INSTALL_ROCM=1
ARG ROCM_VERSION=7.2.3
COPY scripts/install-rocm-toolchain.sh /usr/local/bin/install-rocm-toolchain
RUN chmod 0755 /usr/local/bin/install-rocm-toolchain \
    && TARGETARCH="${TARGETARCH}" INSTALL_ROCM="${INSTALL_ROCM}" ROCM_VERSION="${ROCM_VERSION}" \
       /usr/local/bin/install-rocm-toolchain
ENV ROCM_PATH=/opt/rocm \
    PATH=/opt/rocm/bin:${PATH} \
    LD_LIBRARY_PATH=/opt/rocm/lib
USER runner

ARG BACKEND
FROM backend-${BACKEND} AS selected-backend

ARG BACKEND
ARG CUDA_SERIES=none
ARG ROCM_VERSION=none
USER root
COPY profiles/backends/${BACKEND}.yml /tmp/profiles/backend.yml
RUN profile-packages /tmp/profiles/backend.yml > /tmp/profiles/backend-packages.txt \
    && mapfile -t packages < /tmp/profiles/backend-packages.txt \
    && if (( ${#packages[@]} > 0 )); then \
          apt-get update; \
          apt-get install -y --no-install-recommends "${packages[@]}"; \
        fi \
    && rm -f /tmp/profiles/backend.yml /tmp/profiles/backend-packages.txt \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && printf '%s\n' "${BACKEND}" > /etc/mesh-runner-backend \
    && printf '%s\n' "${CUDA_SERIES}" > /etc/mesh-runner-cuda-series \
    && printf '%s\n' "${ROCM_VERSION}" > /etc/mesh-runner-rocm-version
ENV MESH_RUNNER_BACKEND=${BACKEND}
USER runner

FROM selected-backend AS public
USER root
ENV MESH_RUNNER_ENVIRONMENT=public
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
RUN /usr/local/bin/verify-runner-image public "${BACKEND}" \
    && /__e/node24/bin/node -e 'console.log("node ok")'

FROM selected-backend AS self-hosted

USER root
ARG TARGETARCH
ARG RUNNER_VERSION=2.336.0
ARG RUNNER_SHA256_AMD64=04cf0be1aff4c3ec3554466c39124ca250e3effd8873bb7e8d68535aa9505d5d
ARG RUNNER_SHA256_ARM64=58b758e420b87093fbd4bfddd368074960053e2f1388f01848c82624b90f27d1

COPY scripts/install-actions-runner.sh /usr/local/bin/install-actions-runner
RUN chmod 0755 /usr/local/bin/install-actions-runner \
    && TARGETARCH="${TARGETARCH}" RUNNER_VERSION="${RUNNER_VERSION}" \
       RUNNER_SHA256_AMD64="${RUNNER_SHA256_AMD64}" RUNNER_SHA256_ARM64="${RUNNER_SHA256_ARM64}" \
       /usr/local/bin/install-actions-runner

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

WORKDIR /home/runner
USER runner
ENTRYPOINT ["/home/runner/run.sh"]

FROM self-hosted AS self-hosted-test
ARG BACKEND
RUN /usr/local/bin/verify-runner-image self-hosted "${BACKEND}" \
    && /__e/node24/bin/node -e 'console.log("node ok")'
