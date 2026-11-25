# syntax=docker/dockerfile:1.19
# Windows runs under KVM inside this Linux image. Windows media and disks are
# supplied by the operator and never become public container layers.
FROM docker.io/dockurr/windows@sha256:59f8bed19cfd49cf1701debe34f9df6311e61a4e2ae68aa9f41206e2184e31cc
COPY guest/ /opt/mesh-windows/guest/
COPY tools.json /opt/mesh-windows/tools.json
