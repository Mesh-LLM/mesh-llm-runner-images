#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
python3 -B - "$repository_root/scripts/measure-image-layers.py" <<'PY'
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import shlex
import sys
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("image_layers", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
oci_manifest = "application/vnd.oci.image.manifest.v1+json"
oci_index = "application/vnd.oci.image.index.v1+json"


def encode(value):
    return json.dumps(value, separators=(",", ":")).encode()


def describe(value, media_type):
    raw = encode(value)
    return {"mediaType": media_type, "digest": "sha256:" + hashlib.sha256(raw).hexdigest(), "size": len(raw)}


config = {"architecture": "amd64", "os": "linux", "rootfs": {"type": "layers", "diff_ids": ["sha256:" + "0" * 64] * 4},
          "history": [{"created_by": "WORKDIR /workspace", "empty_layer": True},
                      {"created_by": "RUN true", "empty_layer": False}] * 4,
          "config": {"Labels": {"io.mesh-llm.source.revision": "a" * 40, "io.mesh-llm.runner-images.revision": "b" * 40}}}
manifest = {"schemaVersion": 2, "mediaType": oci_manifest,
            "config": describe(config, "application/vnd.oci.image.config.v1+json"),
            "layers": [{"mediaType": media, "digest": "sha256:" + str(index) * 64, "size": size}
                       for index, (media, size) in enumerate([
                           ("application/vnd.oci.image.layer.v1.tar+gzip", 101),
                           ("application/vnd.oci.image.layer.v1.tar+zstd", 202),
                           ("application/vnd.oci.image.layer.v1.tar", 303),
                           ("application/example.unknown", 404)], 1)]}
child = describe(manifest, oci_manifest) | {"platform": {"os": "linux", "architecture": "amd64"}}
attestation = {"mediaType": oci_manifest, "digest": "sha256:" + "d" * 64, "size": 999999,
               "platform": {"os": "unknown", "architecture": "unknown"},
               "annotations": {"vnd.docker.reference.type": "attestation-manifest"}}
index = {"schemaVersion": 2, "mediaType": oci_index, "manifests": [child, attestation]}
source = {"kind": "fixture", "reference": "fixture:local"}
platform = {"os": "linux", "architecture": "amd64"}


def measure(root=index, image=manifest, configuration=config, requested=platform):
    return module.measure(encode(root), describe(root, root["mediaType"]),
                          lambda _: encode(image), lambda *_: encode(configuration), requested, source)


def reject(callback):
    try:
        callback()
    except (ValueError, KeyError, TypeError):
        return
    raise AssertionError("invalid metadata unexpectedly accepted")


result = measure()
assert result["identity"]["manifest"] == module.descriptor(child)
assert result["identity"]["mesh_revision"] == "a" * 40
assert result["platform"] == platform
assert [layer["compression"] for layer in result["layers"]] == ["gzip", "zstd", "uncompressed", "unknown"]
assert result["totals"] == {
    "layer_descriptor_bytes": 1010, "compressed_layer_descriptor_bytes": 303,
    "uncompressed_layer_descriptor_bytes": 303, "unknown_layer_descriptor_bytes": 404,
    "all_layers_compressed": False, "config_bytes": len(encode(config)),
    "manifest_bytes": len(encode(manifest)), "index_bytes": len(encode(index)),
}
# Direct Docker schema-2 manifests have no index bytes and use the same accounting.
docker_manifest = copy.deepcopy(manifest)
docker_manifest["mediaType"] = "application/vnd.docker.distribution.manifest.v2+json"
docker_manifest["config"]["mediaType"] = "application/vnd.docker.container.image.v1+json"
for layer in docker_manifest["layers"]:
    layer["mediaType"] = "application/vnd.docker.image.rootfs.diff.tar.gzip"
docker_result = measure(root=docker_manifest)
assert docker_result["totals"]["all_layers_compressed"]
assert docker_result["totals"]["compressed_layer_descriptor_bytes"] == 1010
assert docker_result["totals"]["index_bytes"] == 0

reject(lambda: measure(requested={"os": "linux", "architecture": "arm64"}))
reject(lambda: measure(root=index | {"manifests": [child, child]}))
reject(lambda: measure(root=index | {"manifests": [attestation]}))
# Reject layer references and oversized metadata before requesting blob bytes.
for invalid_child in (child | {"mediaType": "application/vnd.oci.image.layer.v1.tar+gzip"},
                      child | {"size": module.MAX_METADATA_BYTES + 1}):
    bad_index = index | {"manifests": [invalid_child]}
    reads = []
    reject(lambda: module.measure(encode(bad_index), describe(bad_index, oci_index),
                                  lambda digest: reads.append(digest), lambda *_: None, platform, source))
    assert reads == []
reject(lambda: measure(image=manifest | {"schemaVersion": 1}))
reject(lambda: measure(configuration=config | {"architecture": "arm64"}))
wrong_platform_config = config | {"architecture": "arm64"}
reject(lambda: measure(root=manifest | {"config": describe(wrong_platform_config, "application/vnd.oci.image.config.v1+json")}, configuration=wrong_platform_config))
reject(lambda: module.decode(encode(manifest), describe(manifest, oci_manifest) | {"size": 1}))
reject(lambda: module.decode(encode(manifest), describe(manifest, oci_manifest) | {"digest": "sha256:" + "f" * 64}))
reject(lambda: module.descriptor({"mediaType": "x", "digest": "sha256:" + "a" * 64, "size": -1}))
reject(lambda: module.descriptor({"mediaType": "x", "digest": "sha256:" + "a" * 64, "size": True}))
reject(lambda: measure(root=manifest | {"artifactType": "application/test"}))
bad_layers = copy.deepcopy(manifest)
bad_layers["layers"][0]["size"] = "101"
reject(lambda: measure(root=bad_layers))
bad_config = config | {"rootfs": {"type": "layers", "diff_ids": []}}
reject(lambda: measure(root=manifest | {"config": describe(bad_config, "application/vnd.oci.image.config.v1+json")}, configuration=bad_config))

# Exercise each CLI transport using in-process command fixtures: no Docker,
# SSH, registry, image export, layer read or container operation can run.
blobs = {describe(index, oci_index)["digest"]: encode(index), child["digest"]: encode(manifest),
         manifest["config"]["digest"]: encode(config)}
calls = []


def fake_command(arguments):
    calls.append(arguments)
    if arguments[:6] == ["docker", "--host", "ssh://fixture-host", "image", "inspect", "fixture:local"]:
        # This deliberately misleading filesystem Size must never enter output.
        return encode([{"Descriptor": describe(index, oci_index), "Size": 999999999999}])
    if arguments[:3] == ["ssh", "--", "fixture-host"]:
        remote = shlex.split(arguments[3])
        assert remote[:9] == ["sudo", "-n", "ctr", "--address", "/explicit/containerd.sock", "--namespace", "fixture-space", "content", "get"]
        return blobs[remote[9]]
    if arguments[:3] == ["skopeo", "inspect", "--raw"]:
        if "--config" in arguments:
            assert arguments[-1] == "docker://registry.invalid:5000/team/image@" + child["digest"]
            return encode(config)
        if arguments[-1] in {"docker://registry.invalid:5000/team/image:tag",
                             "docker://registry.invalid:5000/team/image@" + describe(index, oci_index)["digest"]}:
            return encode(index)
        assert arguments[-1] == "docker://registry.invalid:5000/team/image@" + child["digest"]
        return encode(manifest)
    raise AssertionError(arguments)


def cli(arguments):
    output = io.StringIO()
    with patch.object(sys, "argv", ["measure-image-layers.py", *arguments]), patch.object(module, "command", fake_command), contextlib.redirect_stdout(output):
        module.main()
    return json.loads(output.getvalue())


local = cli(["--local", "fixture:local", "--platform", "linux/amd64", "--ssh-host", "fixture-host",
             "--containerd-address", "/explicit/containerd.sock", "--namespace", "fixture-space", "--sudo"])
assert local["totals"] == result["totals"]
assert len(calls) == 4
assert "999999999999" not in json.dumps(local)
assert "configuration_json" not in local
calls.clear()
with_config = cli(["--local", "fixture:local", "--platform", "linux/amd64", "--ssh-host", "fixture-host",
                   "--containerd-address", "/explicit/containerd.sock", "--namespace", "fixture-space", "--sudo", "--include-config"])
assert with_config["configuration_json"].encode("utf-8") == encode(config)
assert "sha256:" + hashlib.sha256(with_config["configuration_json"].encode("utf-8")).hexdigest() == with_config["identity"]["config"]["digest"]
assert len(with_config["configuration_json"].encode("utf-8")) == with_config["identity"]["config"]["size"]
assert with_config["identity"] == local["identity"] and with_config["totals"] == local["totals"]
assert len(calls) == 4  # Exposing verified config never adds another blob read.
calls.clear()
registry = cli(["--registry", "registry.invalid:5000/team/image:tag", "--platform", "linux/amd64"])
assert registry["identity"] == local["identity"] and registry["totals"] == local["totals"]
assert len(calls) == 3
assert cli(["--registry", "registry.invalid:5000/team/image:tag@" + describe(index, oci_index)["digest"],
            "--platform", "linux/amd64"])["identity"] == registry["identity"]
reject(lambda: cli(["--local", "fixture:local", "--platform", "linux/amd64"]))
reject(lambda: cli(["--registry", "registry.invalid/image", "--platform", "linux/amd64", "--sudo"]))
for invalid_root in (describe(index, oci_index) | {"mediaType": "application/vnd.oci.image.layer.v1.tar+gzip"},
                     describe(index, oci_index) | {"size": module.MAX_METADATA_BYTES + 1}):
    reads = []

    def invalid_root_command(arguments):
        reads.append(arguments)
        assert arguments[0] == "docker", "invalid root must not cause a content read"
        return encode([{"Descriptor": invalid_root}])

    with patch.object(sys, "argv", ["measure-image-layers.py", "--local", "fixture:local", "--platform", "linux/amd64",
                                   "--ssh-host", "fixture-host", "--containerd-address", "/explicit/containerd.sock", "--namespace", "fixture-space"]), patch.object(module, "command", invalid_root_command):
        reject(module.main)
    assert len(reads) == 1
print("Image descriptor identity, platform, compression accounting, and read-only transport fixtures passed")
PY
