#!/usr/bin/env bash
set -euo pipefail
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PYTHONDONTWRITEBYTECODE=1 python3 - "$repository_root" <<'PY'
import hashlib
import copy
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("ui_cache", root / "tests/integration/ui-layer-cache.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
SOURCE = "1" * 40
RUNNER = "2" * 40
IMAGE = "sha256:" + "a" * 64


def write_json(path, value):
    path.write_text(json.dumps(value) + "\n")


def context_fixture(directory):
    context = directory / "context"
    files = {"Cargo.toml": "[workspace]\n", "ci/requirements-ci-python.txt": "pytest==8.4.0\n",
             "crates/mesh-llm-ui/package.json": "{}\n", "crates/mesh-llm-ui/pnpm-lock.yaml": "lockfileVersion: 9\n",
             "crates/mesh-llm-ui/.npmrc": "engine-strict=true\n"}
    for environment in ("public", "self-hosted"):
        bundle = context / "build-context/manifests" / environment
        dependencies = bundle / "dependencies"
        entries = []
        for relative, content in files.items():
            path = dependencies / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
            entries.append({"path": relative, "sha256": hashlib.sha256(content.encode()).hexdigest()})
        write_json(dependencies / "dependency-index.json", {"schema": 1, "files": entries})
        write_json(bundle / "manifest-index.json", {"profile": environment, "source_revision": SOURCE,
                   "manifests": [{**entry, "ecosystem": "fixture"} for entry in entries]})
        (bundle / "source-revision.txt").write_text(SOURCE + "\n")
        (bundle / "profile.txt").write_text(environment + "\n")
    return context


def build_log(phase, image=IMAGE):
    cached = phase != "baseline"
    operations = [
        ("ui-tools", "RUN apt-get install -y packages", "CACHED" if cached else "DONE"),
        ("ui-tools", "RUN /usr/local/bin/install-ui-tools", "CACHED" if cached else "DONE"),
        ("ui-inputs", "RUN prepare-ui-dependencies /tmp/manifest-inputs /ui-manifests", "CACHED" if phase == "ui-switch" else "DONE"),
        ("ui-dependencies", "RUN warm-ui-dependencies /opt/mesh-llm/manifests", "DONE" if phase in ("baseline", "ui-config-change") else "CACHED"),
    ]
    if phase != "ui-switch":
        operations.append(("backend-browser", "RUN install-playwright /tmp/playwright-pin.txt", "CACHED" if cached else "DONE"))
    operations.extend(("public", f"COPY --link --chown=1001:123 --from=ui-dependencies {path} {path}", "DONE")
                      for path in module.DEPENDENCY_PATHS)
    operations.append(("public-test", "RUN verify-runner-image public args", "DONE"))
    lines = []
    for index, (stage, command, status) in enumerate(operations, 1):
        lines.extend((f"#{index} [linux/amd64 {stage} 1/9] {command}", f"#{index} {status}"))
    lines.extend(("#99 exporting to image", f"#99 exporting config {image} done", "#99 DONE 0.1s"))
    return "\n".join(lines) + "\n"


def save_image(directory, phase):
    expected = json.loads((directory / f"{phase}-expected.json").read_text())
    backend = expected["backend"]
    inspected = {"Id": IMAGE, "Os": "linux", "Architecture": "amd64", "Config": {
        "Labels": {"io.mesh-llm.source.revision": expected["source_revision"],
                   "io.mesh-llm.runner-images.revision": RUNNER,
                   "io.mesh-llm.runner.environment": "public", "io.mesh-llm.runner.backend": backend},
        "Env": [f"MESH_RUNNER_BACKEND={backend}", "MESH_RUNNER_ENVIRONMENT=public"]},
        "RootFS": {"Type": "layers", "Layers": [f"sha256:{index:064x}" for index in range(4)]}}
    write_json(directory / f"{phase}-inspect.json", [inspected])
    write_json(directory / f"{phase}-metadata.json", expected["image_metadata"])
    history = [{"CreatedBy": "RUN true # buildkit", "Size": "0", "ID": "<missing>"}]
    history.extend({"CreatedBy": f"COPY --chown=1001:123 {path} {path} # buildkit", "Size": "1", "ID": "<missing>"}
                   for path in module.DEPENDENCY_PATHS)
    history.reverse()
    history[0]["ID"] = IMAGE
    (directory / f"{phase}-history.jsonl").write_text("\n".join(json.dumps(row) for row in history))
    (directory / f"{phase}.log").write_text(build_log(phase))
    save_oci_config(directory, phase)


def save_oci_config(directory, phase):
    image = json.loads((directory / f"{phase}-inspect.json").read_text())[0]
    # OCI marks empty metadata entries explicitly, independently of byte size.
    # A filesystem-producing zero-byte WORKDIR consumes a diffID; the other
    # WORKDIR does not. Docker's human history cannot distinguish these.
    history = [{"created_by": "WORKDIR /home/runner", "empty_layer": True},
               {"created_by": "WORKDIR /workspace"}]
    history += [{"created_by": f"COPY --chown=1001:123 {path} {path} # buildkit"}
                for path in module.DEPENDENCY_PATHS]
    config = {"architecture": "amd64", "os": "linux", "config": image["Config"],
              "rootfs": {"type": "layers", "diff_ids": image["RootFS"]["Layers"]}, "history": history}
    raw = json.dumps(config, separators=(",", ":")) + "\n"
    descriptor = {"mediaType": "application/vnd.oci.image.config.v1+json", "size": len(raw.encode()),
                  "digest": "sha256:" + hashlib.sha256(raw.encode()).hexdigest()}
    root = {"mediaType": "application/vnd.oci.image.index.v1+json", "digest": IMAGE, "size": 123}
    image["Descriptor"] = root
    write_json(directory / f"{phase}-inspect.json", [image])
    write_json(directory / f"{phase}-oci.json", {"schema": 1, "platform": {"os": "linux", "architecture": "amd64"},
               "identity": {"root": root, "config": descriptor}, "configuration_json": raw})
    (directory / f"{phase}.log").write_text(build_log(phase) + f"#99 exporting config {descriptor['digest']} 0.0s done\n")
    return config


class CacheTests(unittest.TestCase):
    def test_shared_verification_wrapper_is_a_real_public_test_step(self):
        text = build_log("baseline").replace("RUN verify-runner-image public args",
            "RUN --network=none bash /opt/mesh-runner-verification/verify-runner-candidate.sh args")
        self.assertEqual(module.parse_steps(text, "baseline")["verify"]["status"], "DONE")
        with self.assertRaises(ValueError):
            module.parse_steps(text.replace("RUN --network=none bash", "COPY --network=none bash"), "baseline")

    def test_completed_step_boundaries(self):
        for phase in ("baseline", "unrelated-change", "ui-config-change", "ui-switch"):
            with self.subTest(phase=phase):
                proof = module.parse_steps(build_log(phase), phase)
                self.assertIn("warm", proof)
        mutations = [
            ("unrelated-change", lambda log: log.replace("#4 CACHED", "#4 DONE")),
            ("ui-config-change", lambda log: log.replace("#4 DONE", "#4 CACHED")),
            ("ui-config-change", lambda log: log.replace("#5 CACHED", "#5 DONE")),
            ("unrelated-change", lambda log: log.replace("#3 DONE", "#3 CACHED")),
            ("baseline", lambda log: log.replace("#4 DONE\n", "")),
            ("baseline", lambda log: log + "#4 ERROR: failed\n"),
            ("baseline", lambda log: log + "#4 CACHED\n"),
            ("baseline", lambda log: log.replace("#99 DONE 0.1s\n", "")),
        ]
        for phase, mutate in mutations:
            with self.subTest(phase=phase, mutate=mutate), self.assertRaises(ValueError):
                module.parse_steps(mutate(build_log(phase)), phase)

    def test_accepts_buildkit_repeated_progress_and_timed_export_lines(self):
        log = build_log("baseline").replace(f"{IMAGE} done", f"{IMAGE} 0.0s done")
        log += "#4 [linux/amd64 ui-dependencies 1/9] RUN warm-ui-dependencies /opt/mesh-llm/manifests\n#4 DONE 1.3s\n"
        self.assertEqual(module.parse_steps(log, "baseline")["completed_exports"], [IMAGE])

    def test_does_not_classify_frontend_resolver_status_as_build_execution(self):
        resolver = (
            "#50 docker-image://docker.io/docker/dockerfile:1.7@sha256:" + "b" * 64 + "\n"
            "#50 DONE 0.1s\n#50 CACHED\n"
        )
        proof = module.parse_steps(resolver + build_log("unrelated-change"), "unrelated-change")
        self.assertEqual(proof["warm"]["status"], "CACHED")
        with self.assertRaises(ValueError):
            module.parse_steps(build_log("baseline") + "#99 CACHED\n", "baseline")

    def test_coherent_mutations_preserve_or_change_only_ui_subset(self):
        with tempfile.TemporaryDirectory() as temporary:
            proof = Path(temporary)
            context_fixture(proof)
            module.initialize(proof, RUNNER, True)
            before = json.loads((proof / "baseline-expected.json").read_text())
            module.mutate(proof, "unrelated-change")
            unrelated = json.loads((proof / "unrelated-change-expected.json").read_text())
            self.assertNotEqual(before["source_revision"], unrelated["source_revision"])
            self.assertEqual(before["image_metadata"]["dependency_index"], unrelated["image_metadata"]["dependency_index"])
            self.assertNotEqual(before["image_metadata"]["manifest_index"], unrelated["image_metadata"]["manifest_index"])
            self.assertEqual(set(unrelated["mutation_paths"]), {"Cargo.toml", "ci/requirements-ci-python.txt"})
            module.mutate(proof, "ui-config-change")
            ui = json.loads((proof / "ui-config-change-expected.json").read_text())
            self.assertNotEqual(ui["image_metadata"]["dependency_index"], unrelated["image_metadata"]["dependency_index"])
            for environment in ("public", "self-hosted"):
                module.read_bundle(proof / "context/build-context/manifests" / environment)
            save_image(proof, "baseline")
            module.check_phase(proof, "baseline")

    def test_rejects_stale_checksum_and_unsafe_manifest_paths_before_mutating(self):
        for bad_path in (False, True):
            with tempfile.TemporaryDirectory() as temporary:
                proof = Path(temporary)
                context = context_fixture(proof)
                bundle = context / "build-context/manifests/public"
                if bad_path:
                    index = json.loads((bundle / "dependencies/dependency-index.json").read_text())
                    index["files"][0]["path"] = "../outside"
                    write_json(bundle / "dependencies/dependency-index.json", index)
                else:
                    (bundle / "dependencies/Cargo.toml").write_text("changed\n")
                with self.assertRaises(ValueError):
                    module.initialize(proof, RUNNER, False)

    def test_rejects_symlinked_bundle_before_any_fixture_writes(self):
        with tempfile.TemporaryDirectory() as temporary:
            proof = Path(temporary)
            context = context_fixture(proof)
            public = context / "build-context/manifests/public"
            moved = proof / "external-public"
            public.rename(moved)
            public.symlink_to(moved, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "symlink"):
                module.initialize(proof, RUNNER, False)
            self.assertFalse((proof / "inputs.json").exists())

    def test_image_and_actual_metadata_must_match_completed_export_and_fixture(self):
        with tempfile.TemporaryDirectory() as temporary:
            proof = Path(temporary)
            context_fixture(proof)
            module.initialize(proof, RUNNER, False)
            save_image(proof, "baseline")
            module.check_phase(proof, "baseline")
            (proof / "baseline.log").write_text(build_log("baseline", "sha256:" + "b" * 64))
            with self.assertRaisesRegex(ValueError, "completed build exports"):
                module.check_phase(proof, "baseline")
            save_image(proof, "baseline")
            metadata = json.loads((proof / "baseline-metadata.json").read_text())
            metadata["source_revision"] = "3" * 40
            write_json(proof / "baseline-metadata.json", metadata)
            with self.assertRaisesRegex(ValueError, "metadata"):
                module.check_phase(proof, "baseline")

    def test_oci_history_proves_layers_with_zero_byte_workdirs(self):
        with tempfile.TemporaryDirectory() as temporary:
            proof = Path(temporary)
            context_fixture(proof)
            module.initialize(proof, RUNNER, False)
            save_image(proof, "baseline")
            save_oci_config(proof, "baseline")
            # Make legacy Docker history ambiguous while preserving real OCI
            # history. New proofs must use the digest-bound config instead.
            history = proof / "baseline-history.jsonl"
            history.write_text(history.read_text().replace("RUN true # buildkit", "WORKDIR /workspace"))
            result = module.check_phase(proof, "baseline")
            self.assertEqual([entry["layer_index"] for entry in result["dependencies"]], [1, 2, 3])

    def test_rejects_tampered_or_unbound_oci_config(self):
        with tempfile.TemporaryDirectory() as temporary:
            proof = Path(temporary)
            context_fixture(proof)
            module.initialize(proof, RUNNER, False)
            save_image(proof, "baseline")
            save_oci_config(proof, "baseline")
            path = proof / "baseline-oci.json"
            receipt = json.loads(path.read_text())
            receipt["configuration_json"] += " "
            write_json(path, receipt)
            with self.assertRaisesRegex(ValueError, "config.*(digest|size)"):
                module.check_phase(proof, "baseline")
            save_oci_config(proof, "baseline")
            receipt = json.loads(path.read_text())
            receipt["identity"]["root"]["digest"] = "sha256:" + "b" * 64
            write_json(path, receipt)
            with self.assertRaisesRegex(ValueError, "root.*identity"):
                module.check_phase(proof, "baseline")

    def test_oci_mapping_rejects_ambiguous_flags_and_invalid_history(self):
        spec = importlib.util.spec_from_file_location("oci_history", root / "tests/integration/compare-dependency-layers.py")
        mapper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mapper)
        config = {"rootfs": {"type": "layers", "diff_ids": [f"sha256:{index:064x}" for index in range(3)]},
                  "history": [{"created_by": f"COPY --chown=1001:123 {path} {path} # buildkit"}
                              for path in module.DEPENDENCY_PATHS]}
        mutations = [
            lambda value: value["history"][0].update(empty_layer="false"),
            lambda value: value["history"][0].update(empty_layer=0),
            lambda value: value["history"][0].update(empty_layer=True),
            lambda value: value["history"][0].update(created_by="COPY /wrong /wrong # buildkit"),
            lambda value: value["rootfs"]["diff_ids"].__setitem__(0, "invalid"),
            lambda value: value["history"].reverse(),
        ]
        for mutate in mutations:
            changed = copy.deepcopy(config)
            mutate(changed)
            with self.subTest(mutate=mutate), self.assertRaises(ValueError):
                mapper.dependency_layers_from_config(changed, module.DEPENDENCY_PATHS)

    def test_ui_switch_requires_identical_physical_dependency_layers(self):
        with tempfile.TemporaryDirectory() as temporary:
            proof = Path(temporary)
            context_fixture(proof)
            module.initialize(proof, RUNNER, True)
            module.mutate(proof, "unrelated-change")
            module.mutate(proof, "ui-config-change")
            module.snapshot(proof, "ui-switch", "ui", [])
            for phase in ("baseline", "unrelated-change", "ui-config-change", "ui-switch"):
                save_image(proof, phase)
            module.check_all(proof)
            path = proof / "ui-switch-inspect.json"
            inspected = json.loads(path.read_text())
            inspected[0]["RootFS"]["Layers"][2] = "sha256:" + "f" * 64
            write_json(path, inspected)
            save_oci_config(proof, "ui-switch")
            with self.assertRaisesRegex(ValueError, "dependency layer changed"):
                module.check_all(proof)

    def test_evidence_only_does_not_invoke_docker(self):
        with tempfile.TemporaryDirectory() as temporary:
            proof = Path(temporary)
            context_fixture(proof)
            module.initialize(proof, RUNNER, False)
            module.mutate(proof, "unrelated-change")
            module.mutate(proof, "ui-config-change")
            for phase in ("baseline", "unrelated-change", "ui-config-change"):
                save_image(proof, phase)
            # A poison executable proves this mode does not even inspect Docker.
            tools = proof / "bin"
            tools.mkdir()
            marker = proof / "docker-was-invoked"
            (tools / "docker").write_text(f"#!/bin/sh\ntouch '{marker}'\nexit 99\n")
            (tools / "docker").chmod(0o755)
            result = subprocess.run(["bash", str(root / "tests/integration/ui-layer-cache.sh"), "--evidence-only", str(proof)],
                                    capture_output=True, text=True, env={**os.environ, "PATH": f"{tools}:{os.environ['PATH']}"})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(marker.exists())


unittest.main(argv=["ui-layer-cache"], verbosity=1)
PY
