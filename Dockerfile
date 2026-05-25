FROM myoung34/github-runner:2.334.0-ubuntu-jammy

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY scripts/install-cuda-toolchain.sh /usr/local/bin/install-cuda-toolchain.sh

RUN chmod +x /usr/local/bin/install-cuda-toolchain.sh \
  && /usr/local/bin/install-cuda-toolchain.sh \
  && rm -f /usr/local/bin/install-cuda-toolchain.sh

ENV CUDA_HOME=/usr/local/cuda \
    PATH=/usr/local/cuda/bin:/usr/local/nvidia/bin:${PATH} \
    LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64
