# syntax=docker/dockerfile:1.7

FROM mcr.microsoft.com/dotnet/runtime-deps:8.0-noble AS toolchain

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
      io.mesh-llm.source.revision="${MESH_LLM_REVISION}"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    CARGO_HOME=/home/runner/.cargo \
    RUSTUP_HOME=/home/runner/.rustup \
    PNPM_HOME=/home/runner/.local/share/pnpm \
    VIRTUAL_ENV=/opt/mesh-llm/venv \
    PATH=/opt/mesh-llm/venv/bin:/home/runner/.local/share/pnpm:/home/runner/.cargo/bin:${PATH} \
    CARGO_INCREMENTAL=0 \
    CARGO_NET_RETRY=10 \
    CARGO_HTTP_MULTIPLEXING=false \
    ImageOS=ubuntu24

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY profiles/common-apt.txt /tmp/common-apt.txt
COPY profiles/${RUNNER_ENVIRONMENT}-apt.txt /tmp/environment-apt.txt
RUN packages="$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' /tmp/common-apt.txt /tmp/environment-apt.txt | sort -u | tr '\n' ' ')" \
    && apt-get update \
    && apt-get install -y --no-install-recommends software-properties-common \
    && add-apt-repository -y universe \
    && apt-get update \
    && apt-get install -y --no-install-recommends ${packages} \
    && rm -f /tmp/common-apt.txt /tmp/environment-apt.txt \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 123 docker \
    && useradd --create-home --uid 1001 --gid 123 --shell /bin/bash runner \
    && usermod -aG sudo runner \
    && printf '%%sudo ALL=(ALL:ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/runner \
    && chmod 0440 /etc/sudoers.d/runner \
    && mkdir -p /opt/mesh-llm \
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

FROM toolchain AS public
ENV MESH_RUNNER_ENVIRONMENT=public
ENTRYPOINT []
CMD ["/bin/bash"]

FROM public AS public-test
RUN /usr/local/bin/verify-runner-image public

FROM toolchain AS self-hosted

USER root
ARG TARGETARCH
ARG RUNNER_VERSION=2.336.0
ARG RUNNER_SHA256_AMD64=04cf0be1aff4c3ec3554466c39124ca250e3effd8873bb7e8d68535aa9505d5d
ARG RUNNER_SHA256_ARM64=58b758e420b87093fbd4bfddd368074960053e2f1388f01848c82624b90f27d1
ARG INSTALL_CUDA=1
ARG CUDA_SERIES=12-9

COPY scripts/install-actions-runner.sh /usr/local/bin/install-actions-runner
COPY scripts/install-cuda-toolchain.sh /usr/local/bin/install-cuda-toolchain
RUN chmod 0755 /usr/local/bin/install-actions-runner /usr/local/bin/install-cuda-toolchain \
    && TARGETARCH="${TARGETARCH}" RUNNER_VERSION="${RUNNER_VERSION}" \
       RUNNER_SHA256_AMD64="${RUNNER_SHA256_AMD64}" RUNNER_SHA256_ARM64="${RUNNER_SHA256_ARM64}" \
       /usr/local/bin/install-actions-runner \
    && TARGETARCH="${TARGETARCH}" INSTALL_CUDA="${INSTALL_CUDA}" CUDA_SERIES="${CUDA_SERIES}" \
       /usr/local/bin/install-cuda-toolchain

ENV MESH_RUNNER_ENVIRONMENT=self-hosted \
    RUNNER_MANUALLY_TRAP_SIG=1 \
    ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT=1 \
    CUDA_HOME=/usr/local/cuda \
    PATH=/usr/local/cuda/bin:${PATH} \
    LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64

WORKDIR /home/runner
USER runner
ENTRYPOINT ["/home/runner/run.sh"]

FROM self-hosted AS self-hosted-test
RUN /usr/local/bin/verify-runner-image self-hosted
