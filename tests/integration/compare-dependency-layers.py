#!/usr/bin/env python3
"""Compare local image dependency diffIDs using validated inspect/history data."""

import json
import re
import sys
from pathlib import Path

DEPENDENCY_PATHS = (
    "/opt/mesh-llm/",
    "/home/runner/.cargo/registry/",
    "/home/runner/.cargo/git/",
    "/home/runner/.npm/",
    "/home/runner/.local/share/pnpm/store/",
)
METADATA_OPERATIONS = {
    "ARG", "CMD", "ENTRYPOINT", "ENV", "EXPOSE", "HEALTHCHECK", "LABEL",
    "MAINTAINER", "ONBUILD", "SHELL", "STOPSIGNAL", "USER", "VOLUME",
}


def dependency_layers(inspect, history):
    """Fail closed rather than guess a history-to-diffID correspondence."""
    if not history or history[0]["ID"] != inspect["Id"]:
        raise ValueError("history is not bound to the inspected image ID")
    layers = inspect["RootFS"]["Layers"]
    if inspect["RootFS"]["Type"] != "layers" or not all(
        re.fullmatch(r"sha256:[0-9a-f]{64}", layer) for layer in layers
    ):
        raise ValueError("invalid image RootFS diffIDs")
    filesystem = []
    for row in reversed(history):  # Docker history is newest first.
        command = row["CreatedBy"]
        size = int(row["Size"])  # --human=false is mandatory.
        if "#(nop)" in command:
            operation = command.split("#(nop)", 1)[1].split()[0]
        elif re.match(r"^/bin/(?:ba)?sh -c ", command):
            operation = "RUN"
        else:
            operation = command.split()[0]
        if operation in {"RUN", "COPY", "ADD"}:
            filesystem.append(row)
        elif operation == "WORKDIR":
            if size == 0:
                raise ValueError("zero-byte WORKDIR has ambiguous layer history")
            filesystem.append(row)
        elif operation not in METADATA_OPERATIONS or size != 0:
            raise ValueError(f"unsupported or nonempty metadata history: {command}")
    if len(filesystem) != len(layers):
        raise ValueError(f"history/layer count mismatch: {len(filesystem)} != {len(layers)}")
    return dependency_copy_layers(layers, filesystem, DEPENDENCY_PATHS)


def dependency_layers_from_config(config, paths=DEPENDENCY_PATHS):
    """Use OCI's explicit empty_layer flag, never a Docker history byte size."""
    layers = config["rootfs"]["diff_ids"]
    history = config["history"]
    if config["rootfs"]["type"] != "layers" or not isinstance(layers, list) or not all(
        isinstance(layer, str) and re.fullmatch(r"sha256:[0-9a-f]{64}", layer) for layer in layers
    ):
        raise ValueError("invalid OCI configuration rootfs diffIDs")
    if not isinstance(history, list) or not history:
        raise ValueError("missing OCI configuration history")
    filesystem = []
    for row in history:  # OCI configuration history is oldest first.
        if not isinstance(row, dict) or type(row.get("empty_layer", False)) is not bool:
            raise ValueError("invalid OCI empty_layer history marker")
        command = row.get("created_by", "")
        if not isinstance(command, str):
            raise ValueError("invalid OCI history command")
        if not row.get("empty_layer", False):
            filesystem.append({"CreatedBy": command})
    if len(filesystem) != len(layers):
        raise ValueError("OCI nonempty history count does not match rootfs diffIDs")
    return dependency_copy_layers(layers, filesystem, paths)


def dependency_copy_layers(layers, filesystem, paths):
    result = []
    for path in paths:
        expected = ["COPY", "--chown=1001:123", path, path, "#", "buildkit"]
        matches = [(index, row) for index, row in enumerate(filesystem)
                   if row["CreatedBy"].split() == expected]
        if len(matches) != 1:
            raise ValueError(f"expected one physical dependency COPY for {path}")
        index, row = matches[0]
        result.append({"path": path, "layer_index": index, "diff_id": layers[index],
                       "created_by": row["CreatedBy"]})
    indexes = [row["layer_index"] for row in result]
    if not indexes or indexes != list(range(indexes[0], indexes[0] + len(paths))):
        raise ValueError("dependency COPY layers are not contiguous and ordered")
    return result


def compare(proof_directory):
    inputs = json.loads((proof_directory / "inputs.json").read_text())
    images = {}
    for phase, expected_backend in (("dependency-change", "vulkan"), ("cpu-switch", "cpu")):
        inspected = json.loads((proof_directory / f"{phase}-inspect.json").read_text())
        if len(inspected) != 1:
            raise ValueError("expected one inspected image")
        inspect = inspected[0]
        history = [json.loads(line) for line in
                   (proof_directory / f"{phase}-history.jsonl").read_text().splitlines()]
        exports = re.findall(
            r"^#\d+ exporting (?:config|manifest|manifest list) (sha256:[0-9a-f]{64}) done$",
            (proof_directory / f"{phase}.log").read_text(), re.MULTILINE,
        )
        if inspect["Id"] not in exports:
            raise ValueError(f"{phase}: local image ID is absent from completed build exports")
        labels = inspect["Config"]["Labels"]
        if labels.get("io.mesh-llm.source.revision") != inputs["synthetic_fixture_revision"]:
            raise ValueError(f"{phase}: source fixture revision mismatch")
        if labels.get("io.mesh-llm.runner-images.revision") != inputs["runner_images_revision"]:
            raise ValueError(f"{phase}: runner source revision mismatch")
        if f'{inspect["Os"]}/{inspect["Architecture"]}' != inputs["platform"]:
            raise ValueError(f"{phase}: platform mismatch")
        if f"MESH_RUNNER_BACKEND={expected_backend}" not in inspect["Config"]["Env"]:
            raise ValueError(f"{phase}: backend mismatch")
        images[phase] = {"image_id": inspect["Id"], "rootfs_layer_count": len(inspect["RootFS"]["Layers"]),
                         "dependencies": dependency_layers(inspect, history)}
    for original, switched in zip(images["dependency-change"]["dependencies"],
                                  images["cpu-switch"]["dependencies"]):
        if (original["path"], original["diff_id"]) != (switched["path"], switched["diff_id"]):
            raise ValueError(f"dependency layer changed across backends: {original['path']}")
    output = {"schema": 1, "comparison": "uncompressed filesystem layer diffIDs",
              "all_dependency_layers_identical": True, "images": images}
    (proof_directory / "cpu-switch-layer-proof.json").write_text(json.dumps(output, indent=2) + "\n")
    print("Cross-backend image inspection proved all five dependency layer diffIDs identical")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: compare-dependency-layers.py PROOF_DIRECTORY")
    try:
        compare(Path(sys.argv[1]))
    except (ValueError, KeyError, IndexError, TypeError) as error:
        raise SystemExit(str(error)) from error
