#!/usr/bin/env bash
# Install from a reviewed checkout as root, with an operator-supplied host config.
set -euo pipefail
test "$(id -u)" -eq 0
config=${1:?host.json path required}
image=${2:?prepared launcher image ID required}
[[ "$image" =~ ^sha256:[a-f0-9]{64}$ ]]
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
install -d -m 755 /usr/local/lib/mesh-windows /etc/mesh-windows
install -d -m 700 /var/lib/mesh-windows
install -m 644 "$root/host.py" "$root/vm.py" /usr/local/lib/mesh-windows/
install -m 600 "$config" /etc/mesh-windows/host.json
cat > /usr/local/bin/mesh-windows-host <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec docker run --rm --privileged --pid host --network none --entrypoint nsenter \\
  '$image' -t 1 -m -p -r -w -- /usr/bin/python3 \\
  /usr/local/lib/mesh-windows/host.py "\$@" --owner-pid "\$PPID"
EOF
chmod 755 /usr/local/bin/mesh-windows-host
cat > /etc/systemd/system/mesh-windows-recover.service <<'EOF'
[Unit]
Description=Restore a Windows CI reservation's GPU before leaving quarantine
After=local-fs.target docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/lib/mesh-windows/host.py recover
TimeoutStartSec=600
EOF
cat > /etc/systemd/system/mesh-windows-recover.timer <<'EOF'
[Unit]
Description=Reconcile Windows GPU leases after cancellation, expiry or restart

[Timer]
OnBootSec=5s
OnUnitInactiveSec=15s
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now mesh-windows-recover.timer
systemctl is-active --quiet mesh-windows-recover.timer
