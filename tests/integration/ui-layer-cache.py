#!/usr/bin/env python3
"""Prepare synthetic manifest fixtures and validate retained lean cache evidence.

This program only reads JSON, text and image history. It never invokes Docker
or executes any content collected from an image or build log.
"""

import hashlib
import importlib.util
import json
import re
import sys
import uuid
from pathlib import Path, PurePosixPath

DEPENDENCY_PATHS = ("/opt/mesh-llm/manifests/", "/home/runner/.npm/",
                    "/home/runner/.local/share/pnpm/store/")
UI_INPUT = re.compile(r"^(crates/mesh-llm-ui/)?(package\.json|package-lock\.json|pnpm-lock\.yaml|pnpm-workspace\.yaml|yarn\.lock|\.npmrc)$")
PHASES = ("baseline", "unrelated-change", "ui-config-change", "ui-switch")
SHA = re.compile(r"^[0-9a-f]{40}$")


def read_json(path):
    return json.loads(path.read_text())


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def regular_path(root, relative):
    path = PurePosixPath(relative)
    if not relative or path.is_absolute() or str(path) != relative or any(part in {".", ".."} for part in path.parts):
        raise ValueError(f"unsafe manifest path: {relative}")
    result = root
    for part in path.parts:
        result /= part
        if result.is_symlink():
            raise ValueError(f"symlink in manifest path: {relative}")
    if not result.is_file():
        raise ValueError(f"missing regular manifest: {relative}")
    return result


def read_bundle(bundle):
    """Validate both indexes against bytes before changing the copied fixture."""
    source = (bundle / "source-revision.txt").read_text().strip()
    audit = read_json(bundle / "manifest-index.json")
    index = read_json(bundle / "dependencies/dependency-index.json")
    if not SHA.fullmatch(source) or audit["source_revision"] != source:
        raise ValueError("bundle source revision mismatch")
    if audit["profile"] != bundle.name or (bundle / "profile.txt").read_text().strip() != bundle.name:
        raise ValueError("bundle profile mismatch")
    if index["schema"] != 1 or not isinstance(index["files"], list) or not isinstance(audit["manifests"], list):
        raise ValueError("invalid manifest index schema")
    indexed = {}
    for entry in index["files"]:
        relative = entry["path"]
        path = regular_path(bundle / "dependencies", relative)
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if relative in indexed or entry["sha256"] != actual:
            raise ValueError(f"duplicate or stale dependency checksum: {relative}")
        indexed[relative] = actual
    audited = set()
    for entry in audit["manifests"]:
        relative = entry["path"]
        if relative in audited or indexed.get(relative) != entry["sha256"]:
            raise ValueError(f"duplicate or stale audit checksum: {relative}")
        audited.add(relative)
    return {"source_revision": source, "manifest_index": audit, "dependency_index": index}


def read_bundles(proof):
    for environment in ("public", "self-hosted"):
        # cp -R preserves symlinks. Reject any path that could make mutations
        # escape the retained fixture and reach the caller's prepared context.
        for relative in ("manifest-index.json", "source-revision.txt", "profile.txt", "dependencies/dependency-index.json"):
            regular_path(proof / "context", f"build-context/manifests/{environment}/{relative}")
    result = {environment: read_bundle(proof / "context/build-context/manifests" / environment)
              for environment in ("public", "self-hosted")}
    if result["public"]["source_revision"] != result["self-hosted"]["source_revision"]:
        raise ValueError("public and self-hosted fixture source revisions differ")
    return result


def snapshot(proof, phase, backend, mutation_paths):
    inputs = read_json(proof / "inputs.json")
    bundles = read_bundles(proof)
    public = bundles["public"]
    subset = {"schema": 1, "files": sorted(
        (entry for entry in public["dependency_index"]["files"] if UI_INPUT.fullmatch(entry["path"])),
        key=lambda entry: entry["path"])}
    required = {"crates/mesh-llm-ui/package.json", "crates/mesh-llm-ui/pnpm-lock.yaml"}
    if not required.issubset({entry["path"] for entry in subset["files"]}):
        raise ValueError("UI manifest and frozen lockfile are required")
    metadata = {"source_revision": public["source_revision"], "runner_images_revision": inputs["runner_images_revision"],
                "bundle_source_revision": public["source_revision"], "profile": "public", "backend": backend,
                "manifest_index": public["manifest_index"], "dependency_index": subset}
    write_json(proof / f"{phase}-expected.json", {"schema": 1, "backend": backend,
               "source_revision": public["source_revision"], "mutation_paths": mutation_paths,
               "image_metadata": metadata, "bundles": bundles})


def initialize(proof, runner_revision, with_ui_switch):
    if not SHA.fullmatch(runner_revision):
        raise ValueError("runner image revision must be a full lowercase Git SHA")
    bundles = read_bundles(proof)
    write_json(proof / "inputs.json", {"schema": 1, "platform": "linux/amd64", "builder": "default",
               "layer_history_format": "oci-config-v1",
               "original_mesh_revision": bundles["public"]["source_revision"],
               "runner_images_revision": runner_revision, "fixture_nonce": uuid.uuid4().hex,
               "with_ui_switch": with_ui_switch})
    snapshot(proof, "baseline", "browser", [])


def mutate(proof, phase):
    previous = {"unrelated-change": "baseline", "ui-config-change": "unrelated-change"}
    if phase not in previous or (proof / f"{phase}-expected.json").exists():
        raise ValueError("invalid or repeated fixture mutation")
    prior = read_json(proof / f"{previous[phase]}-expected.json")
    bundles = read_bundles(proof)
    if bundles != prior["bundles"]:
        raise ValueError("fixture bytes/indexes no longer match the previous phase")
    paths = ["Cargo.toml", "ci/requirements-ci-python.txt"] if phase == "unrelated-change" else ["crates/mesh-llm-ui/.npmrc"]
    # Preflight every source and both audit indexes before mutating any file.
    for environment, bundle in bundles.items():
        audited = {entry["path"] for entry in bundle["manifest_index"]["manifests"]}
        if not set(paths).issubset(audited):
            raise ValueError(f"{environment}: fixture requires audited inputs {paths}")
    inputs = read_json(proof / "inputs.json")
    marker = f"ui-layer-cache fixture {inputs['fixture_nonce']} {phase}"
    revision = hashlib.sha256((inputs["original_mesh_revision"] + marker).encode()).hexdigest()[:40]
    for environment, bundle in bundles.items():
        root = proof / "context/build-context/manifests" / environment
        for relative in paths:
            path = regular_path(root / "dependencies", relative)
            path.write_bytes(path.read_bytes() + f"\n# {marker}\n".encode())
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            for entries in (bundle["dependency_index"]["files"], bundle["manifest_index"]["manifests"]):
                next(entry for entry in entries if entry["path"] == relative)["sha256"] = digest
        bundle["manifest_index"]["source_revision"] = revision
        write_json(root / "dependencies/dependency-index.json", bundle["dependency_index"])
        write_json(root / "manifest-index.json", bundle["manifest_index"])
        (root / "source-revision.txt").write_text(revision + "\n")
    snapshot(proof, phase, "browser", paths)
    current = read_json(proof / f"{phase}-expected.json")
    same_subset = current["image_metadata"]["dependency_index"] == prior["image_metadata"]["dependency_index"]
    if same_subset != (phase == "unrelated-change"):
        raise ValueError("fixture failed to preserve/change the intended UI dependency subset")


def parse_steps(log, phase):
    if phase not in PHASES:
        raise ValueError(f"unknown phase: {phase}")
    steps, statuses, exports = {}, {}, []
    for line in log.splitlines():
        if re.match(r"^#\d+ (ERROR|CANCELED)(?:\b|:)", line) or line.startswith("ERROR:"):
            raise ValueError("failed or canceled BuildKit step")
        header = re.match(r"^(#\d+) \[([^\]]+)\] (RUN|COPY) (.*)$", line)
        if header:
            step_id, label, operation, command = header.groups()
            parts = label.split()
            if len(parts) >= 2 and re.fullmatch(r"\d+/\d+", parts[-1]):
                step = {"id": step_id, "stage": parts[-2], "operation": operation, "command": command}
                if step_id in steps and steps[step_id] != step:
                    raise ValueError("conflicting BuildKit step headers")
                steps[step_id] = step
        terminal = re.match(r"^(#\d+) (CACHED|DONE)(?:\s.*)?$", line)
        if terminal:
            step_id, status = terminal.groups()
            statuses.setdefault(step_id, set()).add(status)
        export = re.match(r"^(#\d+) exporting (?:config|manifest|manifest list) (sha256:[0-9a-f]{64}) (?:[0-9.]+s )?done$", line)
        if export:
            exports.append(export.groups())
    if not exports or any(statuses.get(step_id) != {"DONE"} for step_id, _ in exports):
        raise ValueError("missing completed image export step")
    for step in steps.values():
        if step["id"] not in statuses:
            raise ValueError(f"missing completed step: {step['id']}")
        # Frontend image resolution can report DONE then CACHED under one ID.
        # Only classify the actual RUN/COPY operations used by this proof.
        if len(statuses[step["id"]]) != 1:
            raise ValueError("conflicting BuildKit completion statuses")
        step["status"] = next(iter(statuses[step["id"]]))

    def one(name, stage, operation, text):
        matches = [step for step in steps.values() if step["stage"] == stage
                   and step["operation"] == operation and text in step["command"]]
        if len(matches) != 1:
            raise ValueError(f"expected exactly one {name} step, found {len(matches)}")
        return matches[0]

    warm = one("UI warming", "ui-dependencies", "RUN", "warm-ui-dependencies /opt/mesh-llm/manifests")
    subset = one("UI input filtering", "ui-inputs", "RUN", "prepare-ui-dependencies /tmp/manifest-inputs /ui-manifests")
    one("UI tool installation", "ui-tools", "RUN", "/usr/local/bin/install-ui-tools")
    one("UI package installation", "ui-tools", "RUN", "apt-get install")
    verify = one("public-test verification", "public-test", "RUN", "verify-runner-image public")
    copies = [one(path, "public", "COPY", f"--link --chown=1001:123 --from=ui-dependencies {path} {path}")
              for path in DEPENDENCY_PATHS]
    browser = None if phase == "ui-switch" else one("browser installation", "backend-browser", "RUN", "install-playwright /tmp/playwright-pin.txt")
    if phase != "baseline":
        tools = [step for step in steps.values() if step["stage"] == "ui-tools"]
        if any(step["status"] != "CACHED" for step in tools):
            raise ValueError("UI tools changed across a dependency-only mutation")
        expected = "DONE" if phase == "ui-config-change" else "CACHED"
        if warm["status"] != expected:
            raise ValueError(f"{phase}: UI warm must be {expected}")
        if browser and browser["status"] != "CACHED":
            raise ValueError("browser installation must remain CACHED")
        if phase in {"unrelated-change", "ui-config-change"} and subset["status"] != "DONE":
            raise ValueError("mutated full dependency inputs must rerun UI filtering")
    return {"warm": warm, "subset": subset, "browser": browser, "verify": verify,
            "copies": copies, "completed_exports": [digest for _, digest in exports]}


def check_phase(proof, phase):
    inputs = read_json(proof / "inputs.json")
    expected = read_json(proof / f"{phase}-expected.json")
    expected_backend = "ui" if phase == "ui-switch" else "browser"
    if not SHA.fullmatch(expected["source_revision"]) or expected["backend"] != expected_backend:
        raise ValueError("invalid phase source/backend expectation")
    if phase == "baseline" and expected["source_revision"] != inputs["original_mesh_revision"]:
        raise ValueError("baseline source revision does not match the prepared context")
    parsed = parse_steps((proof / f"{phase}.log").read_text(), phase)
    inspected = read_json(proof / f"{phase}-inspect.json")
    if not isinstance(inspected, list) or len(inspected) != 1:
        raise ValueError("expected one inspected image")
    image = inspected[0]
    if image["Id"] not in parsed["completed_exports"]:
        raise ValueError("local image ID is absent from completed build exports")
    labels = image["Config"]["Labels"]
    required_labels = {"io.mesh-llm.source.revision": expected["source_revision"],
                       "io.mesh-llm.runner-images.revision": inputs["runner_images_revision"],
                       "io.mesh-llm.runner.environment": "public", "io.mesh-llm.runner.backend": expected["backend"]}
    if any(labels.get(key) != value for key, value in required_labels.items()):
        raise ValueError("image source/environment/backend labels mismatch")
    if f"{image['Os']}/{image['Architecture']}" != inputs["platform"]:
        raise ValueError("image platform mismatch")
    for key, value in (("MESH_RUNNER_BACKEND", expected["backend"]), ("MESH_RUNNER_ENVIRONMENT", "public")):
        if [entry for entry in image["Config"]["Env"] if entry.startswith(key + "=")] != [key + "=" + value]:
            raise ValueError("image backend/environment mismatch")
    if read_json(proof / f"{phase}-metadata.json") != expected["image_metadata"]:
        raise ValueError("actual image metadata does not match the prepared fixture")
    spec = importlib.util.spec_from_file_location("layer_history", Path(__file__).with_name("compare-dependency-layers.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    receipt = read_json(proof / f"{phase}-oci.json")
    identity = receipt["identity"]
    descriptor = identity["config"]
    raw = receipt["configuration_json"].encode("utf-8")
    if descriptor["mediaType"] not in {"application/vnd.oci.image.config.v1+json", "application/vnd.docker.container.image.v1+json"}:
        raise ValueError("unsupported OCI config media type")
    if type(descriptor["size"]) is not int or len(raw) != descriptor["size"]:
        raise ValueError("OCI config size does not match its descriptor")
    if "sha256:" + hashlib.sha256(raw).hexdigest() != descriptor["digest"]:
        raise ValueError("OCI config digest does not match its descriptor")
    if descriptor["digest"] not in parsed["completed_exports"]:
        raise ValueError("OCI config digest is absent from completed build exports")
    inspected_root = {key: image["Descriptor"][key] for key in ("mediaType", "digest", "size")}
    if identity["root"] != inspected_root or identity["root"]["digest"] not in parsed["completed_exports"]:
        raise ValueError("OCI root descriptor identity does not match the inspected build")
    if image["Id"] not in {identity["root"]["digest"], descriptor["digest"]}:
        raise ValueError("OCI root/config identity does not match the immutable image ID")
    config = json.loads(raw)
    if f"{config['os']}/{config['architecture']}" != inputs["platform"]:
        raise ValueError("OCI config platform mismatch")
    if config["rootfs"] != {"type": image["RootFS"]["Type"], "diff_ids": image["RootFS"]["Layers"]}:
        raise ValueError("OCI config rootfs does not match the inspected image")
    if config["config"].get("Labels") != image["Config"].get("Labels") or config["config"].get("Env") != image["Config"].get("Env"):
        raise ValueError("OCI config labels/environment do not match the inspected image")
    layers = module.dependency_layers_from_config(config, DEPENDENCY_PATHS)
    result = {"schema": 1, "phase": phase, "image_id": image["Id"], "source_revision": expected["source_revision"],
              "backend": expected["backend"], "steps": parsed, "dependencies": layers, "layer_history_format": "oci-config-v1"}
    write_json(proof / f"{phase}-proof.json", result)
    return result


def check_all(proof):
    inputs = read_json(proof / "inputs.json")
    phases = PHASES if inputs["with_ui_switch"] else PHASES[:3]
    evidence = {phase: check_phase(proof, phase) for phase in phases}
    expected = {phase: read_json(proof / f"{phase}-expected.json") for phase in phases}
    baseline_subset = expected["baseline"]["image_metadata"]["dependency_index"]
    unrelated_subset = expected["unrelated-change"]["image_metadata"]["dependency_index"]
    changed_subset = expected["ui-config-change"]["image_metadata"]["dependency_index"]
    if baseline_subset != unrelated_subset or unrelated_subset == changed_subset:
        raise ValueError("fixture evidence does not demonstrate the intended UI subset boundaries")
    if len({expected[phase]["source_revision"] for phase in PHASES[:3]}) != 3:
        raise ValueError("mutation phases require distinct synthetic source revisions")
    if inputs["with_ui_switch"] and (expected["ui-switch"]["source_revision"] != expected["ui-config-change"]["source_revision"]
            or expected["ui-switch"]["image_metadata"]["dependency_index"] != changed_subset):
        raise ValueError("UI backend switch must reuse the same dependency fixture")
    comparisons = [("baseline", "unrelated-change")]
    if inputs["with_ui_switch"]:
        comparisons.append(("ui-config-change", "ui-switch"))
    for left, right in comparisons:
        for original, changed in zip(evidence[left]["dependencies"], evidence[right]["dependencies"]):
            if (original["path"], original["diff_id"]) != (changed["path"], changed["diff_id"]):
                raise ValueError(f"dependency layer changed between {left} and {right}: {original['path']}")
    write_json(proof / "result.json", {"schema": 1, "passed": True, "phases": evidence,
               "identical_dependency_layer_comparisons": comparisons,
               "comparison": "completed BuildKit cache statuses and uncompressed filesystem layer diffIDs"})
    print(f"Lean UI cache boundaries passed; evidence: {proof}")


def main(arguments):
    command, directory, *rest = arguments
    proof = Path(directory)
    if command == "initialize" and len(rest) == 2 and rest[1] in {"true", "false"}:
        initialize(proof, rest[0], rest[1] == "true")
    elif command == "mutate" and len(rest) == 1:
        mutate(proof, rest[0])
    elif command == "ui-switch" and not rest:
        snapshot(proof, "ui-switch", "ui", [])
    elif command == "check-phase" and len(rest) == 1:
        check_phase(proof, rest[0])
    elif command == "check" and not rest:
        check_all(proof)
    else:
        raise ValueError("invalid ui-layer-cache evidence command")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (ValueError, KeyError, IndexError, TypeError, OSError) as error:
        raise SystemExit(str(error)) from error
