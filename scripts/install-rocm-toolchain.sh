#!/usr/bin/env bash
set -euo pipefail

: "${TARGETARCH:?TARGETARCH is required}"
: "${INSTALL_ROCM:=1}"
: "${ROCM_VERSION:=7.2.3}"

if [[ "$INSTALL_ROCM" != "1" ]]; then
  echo "Skipping ROCm toolkit for INSTALL_ROCM=${INSTALL_ROCM}"
  exit 0
fi

if [[ "$TARGETARCH" != "amd64" ]]; then
  echo "ROCm runner images currently support only amd64, not ${TARGETARCH}" >&2
  exit 1
fi

install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://repo.radeon.com/rocm/rocm.gpg.key \
  | gpg --dearmor -o /etc/apt/keyrings/rocm.gpg
printf '%s\n' \
  "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/${ROCM_VERSION}/ noble main" \
  > /etc/apt/sources.list.d/rocm.list
cat > /etc/apt/preferences.d/rocm-pin-600 <<'EOF'
Package: *
Pin: origin repo.radeon.com
Pin-Priority: 600
EOF

apt-get update
apt-get install -y --no-install-recommends \
  hip-dev \
  hipblas-dev \
  hipcc \
  rocblas-dev \
  rocm-device-libs
apt-get clean
rm -rf /var/lib/apt/lists/*

test -d /opt/rocm
test -x /opt/rocm/bin/hipcc
test -f /opt/rocm/include/hipblas/hipblas.h
find /opt/rocm/lib -name 'librocblas.so*' -print -quit | grep -q .
