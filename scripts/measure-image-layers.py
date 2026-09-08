#!/usr/bin/env python3
"""Read image metadata only; descriptor bytes are not filesystem size or pull savings."""

import argparse
import hashlib
import json
import re
import shlex
import subprocess
import sys


INDEX_TYPES = {"application/vnd.oci.image.index.v1+json", "application/vnd.docker.distribution.manifest.list.v2+json"}
MANIFEST_TYPES = {"application/vnd.oci.image.manifest.v1+json", "application/vnd.docker.distribution.manifest.v2+json"}
CONFIG_TYPES = {"application/vnd.oci.image.config.v1+json", "application/vnd.docker.container.image.v1+json"}
MAX_METADATA_BYTES = 16 * 1024 * 1024
COMPRESSION = {
    "application/vnd.oci.image.layer.v1.tar+gzip": "gzip",
    "application/vnd.oci.image.layer.nondistributable.v1.tar+gzip": "gzip",
    "application/vnd.docker.image.rootfs.diff.tar.gzip": "gzip",
    "application/vnd.docker.image.rootfs.foreign.diff.tar.gzip": "gzip",
    "application/vnd.oci.image.layer.v1.tar+zstd": "zstd",
    "application/vnd.oci.image.layer.nondistributable.v1.tar+zstd": "zstd",
    "application/vnd.oci.image.layer.v1.tar": "uncompressed",
    "application/vnd.oci.image.layer.nondistributable.v1.tar": "uncompressed",
    "application/vnd.docker.image.rootfs.diff.tar": "uncompressed",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def command(arguments):
    result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, check=False)
    require(result.returncode == 0, f"{arguments[0]} failed: {result.stderr.decode(errors='replace')[-2000:].strip()}")
    require(len(result.stdout) <= MAX_METADATA_BYTES, "metadata exceeds 16 MiB")
    return result.stdout


def descriptor(value):
    require(isinstance(value, dict), "missing descriptor")
    require(isinstance(value.get("mediaType"), str) and value["mediaType"], "missing descriptor media type")
    require(isinstance(value.get("digest"), str) and re.fullmatch(r"sha256:[0-9a-f]{64}", value["digest"]), "unsupported or invalid descriptor digest")
    require(type(value.get("size")) is int and value["size"] >= 0, "invalid descriptor size")
    return {key: value[key] for key in ("mediaType", "digest", "size")}


def metadata_descriptor(value, allowed_types):
    value = descriptor(value)
    require(value["mediaType"] in allowed_types, "descriptor is not supported image metadata")
    require(value["size"] <= MAX_METADATA_BYTES, "metadata descriptor exceeds 16 MiB")
    return value


def decode(raw, expected=None):
    value = json.loads(raw)
    if expected is not None:
        expected = descriptor(expected)
        require(len(raw) == expected["size"], "metadata size does not match descriptor")
        require("sha256:" + hashlib.sha256(raw).hexdigest() == expected["digest"], "metadata digest does not match descriptor")
    require(isinstance(value, dict), "metadata must be a JSON object")
    return value


def matches_platform(actual, wanted):
    return isinstance(actual, dict) and all(actual.get(key) == value for key, value in wanted.items())


def measure(root_raw, root_descriptor, read_manifest, read_config, platform, source, include_config=False):
    root_descriptor = metadata_descriptor(root_descriptor, INDEX_TYPES | MANIFEST_TYPES)
    root = decode(root_raw, root_descriptor)
    require(root.get("schemaVersion") == 2 and root.get("mediaType") == root_descriptor["mediaType"], "unsupported root manifest schema or media type")
    selected = root_descriptor
    index_bytes = 0
    if root_descriptor["mediaType"] in INDEX_TYPES:
        require(isinstance(root.get("manifests"), list), "index has no manifest descriptors")
        require(all(isinstance(entry, dict) and isinstance(entry.get("annotations", {}), dict)
                    for entry in root["manifests"]), "invalid index entries")
        candidates = [entry for entry in root["manifests"] if matches_platform(entry.get("platform"), platform)
                      and entry.get("annotations", {}).get("vnd.docker.reference.type") != "attestation-manifest"]
        require(len(candidates) == 1, "platform must select exactly one runnable image manifest")
        # Check before reading: an index can also reference layer/artifact blobs.
        selected = metadata_descriptor(candidates[0], MANIFEST_TYPES)
        index_bytes = root_descriptor["size"]
        root = decode(read_manifest(selected["digest"]), selected)
    require(selected["mediaType"] in MANIFEST_TYPES and root.get("mediaType") == selected["mediaType"]
            and root.get("schemaVersion") == 2, "selected descriptor is not an OCI/Docker image manifest")
    require(not root.get("artifactType") and not root.get("subject"), "artifact manifests are not runnable images")
    config_descriptor = metadata_descriptor(root.get("config"), CONFIG_TYPES)
    config_raw = read_config(selected["digest"], config_descriptor["digest"])
    config = decode(config_raw, config_descriptor)
    require(matches_platform(config, platform), "configuration platform does not match requested platform")
    require(isinstance(root.get("layers"), list), "manifest has no layer list")
    require(isinstance(config.get("rootfs"), dict) and config["rootfs"].get("type") == "layers"
            and isinstance(config["rootfs"].get("diff_ids"), list)
            and len(config["rootfs"]["diff_ids"]) == len(root["layers"]), "configuration rootfs does not match layer list")
    layers = []
    for index, entry in enumerate(root["layers"]):
        item = descriptor(entry)
        layers.append({"index": index, **item, "compression": COMPRESSION.get(item["mediaType"], "unknown")})
    runtime_config = config.get("config") or {}
    require(isinstance(runtime_config, dict), "invalid runtime configuration")
    labels = runtime_config.get("Labels") or {}
    require(isinstance(labels, dict), "invalid image labels")
    result = {
        "schema": 1,
        "source": source,
        "platform": {key: config[key] for key in ("os", "architecture", "variant") if key in config},
        "identity": {"root": root_descriptor, "manifest": selected, "config": config_descriptor,
                     "mesh_revision": labels.get("io.mesh-llm.source.revision"),
                     "runner_images_revision": labels.get("io.mesh-llm.runner-images.revision")},
        "layers": layers,
        "totals": {
            "layer_descriptor_bytes": sum(item["size"] for item in layers),
            "compressed_layer_descriptor_bytes": sum(item["size"] for item in layers if item["compression"] in {"gzip", "zstd"}),
            "uncompressed_layer_descriptor_bytes": sum(item["size"] for item in layers if item["compression"] == "uncompressed"),
            "unknown_layer_descriptor_bytes": sum(item["size"] for item in layers if item["compression"] == "unknown"),
            "all_layers_compressed": all(item["compression"] in {"gzip", "zstd"} for item in layers),
            "config_bytes": config_descriptor["size"],
            "manifest_bytes": selected["size"],
            "index_bytes": index_bytes,
        },
        "scope": "One runnable platform; attestation and other-platform blobs excluded. Descriptor sums are not pull savings or filesystem sizes.",
    }
    if include_config:
        # Retain original bytes for independent digest checks in offline proof.
        # history.empty_layer distinguishes metadata from empty filesystem layers.
        result["configuration_json"] = config_raw.decode("utf-8")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sources = parser.add_mutually_exclusive_group(required=True)
    sources.add_argument("--local", metavar="IMAGE", help="Read a Docker image through an explicitly configured SSH containerd host")
    sources.add_argument("--registry", metavar="IMAGE", help="Read registry metadata with skopeo; no image pull")
    parser.add_argument("--platform", required=True, help="OS/ARCH[/VARIANT]")
    parser.add_argument("--ssh-host", help="SSH host or alias; also used for Docker's ssh:// host")
    parser.add_argument("--containerd-address", help="Explicit remote containerd socket path")
    parser.add_argument("--namespace", help="Explicit containerd namespace")
    parser.add_argument("--sudo", action="store_true", help="Run remote ctr through noninteractive sudo")
    parser.add_argument("--include-config", action="store_true", help="Include original UTF-8 configuration_json after digest/size verification")
    args = parser.parse_args()
    require(re.fullmatch(r"[a-z0-9_-]+/[a-z0-9_-]+(?:/[a-z0-9_.-]+)?", args.platform), "invalid platform")
    platform = dict(zip(("os", "architecture", "variant"), args.platform.split("/")))
    if args.local:
        require(args.ssh_host and re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.@-]*", args.ssh_host), "local mode requires an explicit SSH host or alias")
        require(args.containerd_address and args.containerd_address.startswith("/") and args.namespace, "local mode requires an explicit socket path and namespace")
        require(not args.local.startswith("-"), "invalid image reference")
        source = {"kind": "local-containerd", "reference": args.local, "ssh_host": args.ssh_host,
                  "containerd_address": args.containerd_address, "namespace": args.namespace}
        inspected = json.loads(command(["docker", "--host", "ssh://" + args.ssh_host, "image", "inspect", args.local]))
        require(isinstance(inspected, list) and len(inspected) == 1, "expected one Docker image inspection result")
        root_descriptor = metadata_descriptor(inspected[0].get("Descriptor"), INDEX_TYPES | MANIFEST_TYPES)

        def read_manifest(digest):
            remote = (["sudo", "-n"] if args.sudo else []) + ["ctr", "--address", args.containerd_address,
                      "--namespace", args.namespace, "content", "get", digest]
            return command(["ssh", "--", args.ssh_host, shlex.join(remote)])

        def read_config(_manifest_digest, digest):
            return read_manifest(digest)

        root_raw = read_manifest(root_descriptor["digest"])
    else:
        require(not any((args.ssh_host, args.containerd_address, args.namespace, args.sudo)), "local transport options cannot be used with registry mode")
        require(args.registry and not args.registry.startswith("-") and "://" not in args.registry, "registry reference must be an image name, not a URL")
        source = {"kind": "registry", "reference": args.registry}
        repository = args.registry.split("@", 1)[0]
        if ":" in repository.rsplit("/", 1)[-1]:
            repository = repository.rsplit(":", 1)[0]

        def read_manifest(digest):
            return command(["skopeo", "inspect", "--raw", "docker://" + repository + "@" + digest])

        def read_config(manifest_digest, _digest):
            return command(["skopeo", "inspect", "--raw", "--config", "docker://" + repository + "@" + manifest_digest])

        # Skopeo rejects name:tag@digest; the immutable digest takes precedence.
        root_reference = repository + "@" + args.registry.rsplit("@", 1)[1] if "@" in args.registry else args.registry
        root_raw = command(["skopeo", "inspect", "--raw", "docker://" + root_reference])
        root_descriptor = {"mediaType": decode(root_raw).get("mediaType"), "size": len(root_raw),
                           "digest": "sha256:" + hashlib.sha256(root_raw).hexdigest()}
        if "@" in args.registry:
            require(args.registry.rsplit("@", 1)[1] == root_descriptor["digest"], "registry response does not match requested digest")
    print(json.dumps(measure(root_raw, root_descriptor, read_manifest, read_config, platform, source, args.include_config), indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.TimeoutExpired) as error:
        print(f"image metadata measurement failed: {error}", file=sys.stderr)
        sys.exit(1)
