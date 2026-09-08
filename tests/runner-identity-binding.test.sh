#!/usr/bin/env bash
set -euo pipefail
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
python3 -B - "$repository_root" <<'PY'
import importlib.util
from pathlib import Path
import sys
spec = importlib.util.spec_from_file_location("identity_fixtures", Path(sys.argv[1]) / "tests/fixtures/runner_identity.py")
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)
globals().update({name: value for name, value in vars(fixtures).items() if not name.startswith("_")})

class BindingTests(IdentityFixtures):
    def test_index_and_direct_manifest_positive_bind_exact_bytes(self):
        for indexed in (True, False):
            for backend, architecture in (("cpu", "amd64"), ("cpu", "arm64"), ("ui", "amd64"),
                                           ("browser", "amd64"), ("web", "arm64"), ("cuda", "amd64"), ("rocm", "amd64")):
                with self.subTest(indexed=indexed, backend=backend, architecture=architecture):
                    fixture = self.fixture(backend, architecture, indexed)
                    receipt = self.bind(fixture)
                    self.assertEqual(receipt["type"], "mesh-llm-runner-image-identity")
                    self.assertEqual(receipt["oci"]["root"]["digest"], fixture["candidate"]["digest"])
                    self.assertEqual(receipt["oci"]["manifest"]["digest"], fixture["candidate"]["child_digest"])
                    self.assertEqual(receipt["oci"]["config"], json.loads(fixture["manifest_raw"])["config"])
                    self.assertEqual(receipt["runtime"], fixture["runtime"])
                    self.assertEqual(len(receipt["layers"]), 1)

    def test_attestation_descriptor_is_excluded_from_runtime_layers(self):
        receipt = self.bind(self.fixture(attestation=True))
        self.assertEqual(len(receipt["layers"]), 1)
        self.assertEqual(receipt["layers"][0]["size"], len(b"fixture layer"))

    def test_every_actual_catalog_platform_can_bind(self):
        catalog = json.loads((repository / "config/runner-image-families.json").read_text())
        checked = 0
        for backend in catalog["backends"]:
            for environment in backend.get("environments", catalog["environments"]):
                for architecture in backend["architectures"]:
                    with self.subTest(backend=backend["id"], environment=environment, architecture=architecture):
                        fixture = self.fixture(backend["name"], architecture)
                        fixture["candidate"]["environment"] = environment
                        fixture["candidate"]["backend"] = {key: backend[key] for key in ("id", "name", "cuda_series", "rocm_version")}
                        fixture["runtime"]["family"] = {"environment": environment, "backend": backend["name"],
                            "cuda_series": backend["cuda_series"], "rocm_version": backend["rocm_version"]}
                        receipt = self.bind(fixture)
                        self.assertEqual(receipt["backend_id"], backend["id"])
                        checked += 1
        self.assertEqual(checked, 23)

    def test_root_child_and_manifest_digest_mismatches_fail(self):
        for mutation in ("root-digest", "child-digest", "root-bytes", "manifest-bytes"):
            with self.subTest(mutation=mutation):
                fixture = self.fixture()
                if mutation == "root-digest": fixture["candidate"]["digest"] = "sha256:" + "a" * 64
                elif mutation == "child-digest": fixture["candidate"]["child_digest"] = "sha256:" + "a" * 64
                elif mutation == "root-bytes": fixture["root_raw"] += b" "
                else: fixture["manifest_raw"] += b" "
                self.reject(fixture)

    def test_index_platform_and_ambiguous_runtime_selection_fail(self):
        for mutation in ("wrong-platform", "duplicate", "missing", "runtime-attestation", "size"):
            with self.subTest(mutation=mutation):
                fixture = self.fixture()
                index = json.loads(fixture["root_raw"])
                entry = index["manifests"][0]
                if mutation == "wrong-platform": entry["platform"] = {"os": "linux", "architecture": "arm64"}
                elif mutation == "duplicate": index["manifests"].append(copy.deepcopy(entry))
                elif mutation == "missing": index["manifests"] = []
                elif mutation == "runtime-attestation": entry["annotations"] = {"vnd.docker.reference.type": "attestation-manifest"}
                else: entry["size"] += 1
                self.update_index(fixture, index)
                self.reject(fixture)

    def test_candidate_and_runtime_source_platform_family_mismatches_fail(self):
        for category, key, value in (("source", "mesh_revision", "a" * 40), ("source", "runner_images_revision", "a" * 40),
                                      ("platform", "architecture", "arm64"), ("family", "backend", "vulkan"),
                                      ("family", "environment", "self-hosted")):
            with self.subTest(category=category, key=key):
                fixture = self.fixture()
                fixture["runtime"][category] = {**fixture["runtime"][category], key: value}
                self.reject(fixture, "mismatch")

    def test_verifier_pin_policy_and_expected_tool_mismatches_fail(self):
        for category, key, value in (("verification", "verifier_revision", "a" * 40),
                ("verification", "tool_pins_sha256", "sha256:" + "a" * 64),
                ("verification", "cache_policy_sha256", "sha256:" + "a" * 64),
                ("expected_tools", "pnpm", "0.0.1")):
            with self.subTest(category=category, key=key):
                fixture = self.fixture()
                fixture["runtime"][category][key] = value
                self.reject(fixture, "mismatch")

    def test_actual_tools_must_match_pins_even_with_recomputed_cache(self):
        for name, version_key in (("node", "version"), ("pnpm", "version"), ("just", "version"),
                                   ("rustc", "release"), ("cargo", "version"), ("sccache", "version"),
                                   ("openai_npm", "version"), ("playwright", "version")):
            with self.subTest(tool=name):
                fixture = self.fixture("web")
                fixture["runtime"]["tools"][name][version_key] = "0.0.1"
                self.refresh_cache(fixture)
                self.reject(fixture, "observed")

    def test_tool_schema_omissions_extras_and_wrong_abi_fail(self):
        mutations = (lambda tools: tools.pop("just"), lambda tools: tools.update(extra={}),
            lambda tools: tools["node"].pop("modules_abi"), lambda tools: tools["pnpm"].update(store_format="../../store"),
            lambda tools: tools["rustc"].update(host="aarch64-unknown-linux-gnu"),
            lambda tools: tools["python"].update(packages_sha256="unknown"))
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                fixture = self.fixture()
                mutation(fixture["runtime"]["tools"])
                self.reject(fixture)

    def test_lean_absent_tools_and_browser_presence_are_enforced(self):
        for backend, tool, observation in (("ui", "cargo", {"version": self.pins["full"]["rust"]}),
                ("ui", "playwright", {"version": self.pins["browser"]["playwright"], "chromium_build": "1234"}),
                ("browser", "playwright", None), ("cpu", "rustc", None)):
            with self.subTest(backend=backend, tool=tool):
                fixture = self.fixture(backend)
                fixture["runtime"]["tools"][tool] = observation
                self.reject(fixture)

    def test_dependency_scope_hash_lifecycle_and_python_lock_fail(self):
        for key, value in (("kind", "ui"), ("index_sha256", "not-a-digest"),
                           ("pnpm_lifecycle", "onnx-skip"), ("python_lock_sha256", "sha256:" + "a" * 64)):
            with self.subTest(key=key):
                fixture = self.fixture()
                fixture["runtime"]["dependencies"][key] = value
                self.refresh_cache(fixture)
                self.reject(fixture)

    def test_cache_epoch_and_fingerprint_drift_fail(self):
        for key in ("epochs", "input_fingerprints"):
            fixture = self.fixture()
            fixture["runtime"]["cache"] = copy.deepcopy(fixture["runtime"]["cache"])
            fixture["runtime"]["cache"][key]["pnpm"] = 99 if key == "epochs" else "sha256:" + "a" * 64
            self.reject(fixture, "cache fingerprint mismatch")

    def test_changed_trusted_files_reject_old_receipt(self):
        for name in ("tool-pins.json", "cache-policy.json", "python-requirements.lock"):
            with self.subTest(name=name):
                fixture = self.fixture()
                path = self.expected / name
                previous = path.read_bytes()
                try:
                    if name.endswith("lock"): path.write_text("example-package==9.9.9\n")
                    else:
                        value = json.loads(previous)
                        if name == "tool-pins.json": value["common"]["pnpm"] = "99.0.0"
                        else: value["epochs"]["pnpm"] += 1
                        path.write_bytes(raw(value))
                    self.reject(fixture)
                finally:
                    path.write_bytes(previous)

    def test_candidate_backend_id_version_relations_fail(self):
        for backend, wrong_id in (("cuda", "cuda13"), ("rocm", "rocm70")):
            fixture = self.fixture(backend)
            fixture["candidate"]["backend"]["id"] = wrong_id
            self.reject(fixture, "family/version mismatch")

    def test_invalid_candidate_repository_and_lean_platform_fail(self):
        fixture = self.fixture()
        fixture["candidate"]["image"] = "ghcr.io/mesh-llm/runner:mutable"
        self.reject(fixture, "repository")
        fixture = self.fixture("ui", "arm64")
        self.reject(fixture, "lean architecture")

    def test_top_level_and_nested_schema_omissions_fail(self):
        for target in ("candidate", "runtime"):
            original = self.fixture()
            for key in original[target]:
                with self.subTest(target=target, key=key):
                    fixture = copy.deepcopy(original)
                    fixture[target].pop(key)
                    self.reject(fixture)
        for category in ("backend", "platform"):
            fixture = self.fixture()
            fixture["candidate"][category].pop(next(iter(fixture["candidate"][category])))
            self.reject(fixture)

    def test_manifest_artifacts_missing_layers_and_bad_descriptors_fail(self):
        for mutation in ("artifact", "subject", "empty-layers", "missing-config", "config-media", "layer-size"):
            with self.subTest(mutation=mutation):
                fixture = self.fixture()
                manifest = json.loads(fixture["manifest_raw"])
                if mutation == "artifact": manifest["artifactType"] = "application/example"
                elif mutation == "subject": manifest["subject"] = manifest["config"]
                elif mutation == "empty-layers": manifest["layers"] = []
                elif mutation == "missing-config": manifest.pop("config")
                elif mutation == "config-media": manifest["config"]["mediaType"] = LAYER
                else: manifest["layers"][0]["size"] = True
                self.update_manifest(fixture, manifest)
                self.reject(fixture)

    def test_invalid_json_and_metadata_size_are_bounded(self):
        for key in ("root_raw", "manifest_raw"):
            fixture = self.fixture()
            fixture[key] = b"not json"
            self.reject(fixture)
            fixture[key] = b" " * (binder.oci.MAX_METADATA_BYTES + 1)
            self.reject(fixture, "16 MiB")

    def test_cli_writes_receipt_only_on_success(self):
        fixture = self.fixture("browser")
        for name, value in (("runtime", raw(fixture["runtime"])), ("candidate", raw(fixture["candidate"])),
                             ("index", fixture["root_raw"]), ("manifest", fixture["manifest_raw"])):
            (self.root / (name + ".json")).write_bytes(value)
        output = self.root / "identity.json"
        arguments = [sys.executable, "-B", str(repository / "scripts/bind-runner-identity.py")]
        for name in ("runtime", "candidate", "index", "manifest"):
            arguments += ["--" + name, str(self.root / (name + ".json"))]
        arguments += ["--expected-directory", str(self.expected), "--verifier-revision", VERIFIER, "--output", str(output)]
        result = subprocess.run(arguments, text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(output.read_text())["runtime"]["family"]["backend"], "browser")
        output.unlink()
        (self.root / "runtime.json").write_text("{malformed json")
        result = subprocess.run(arguments, text=True, capture_output=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("runner identity binding failed", result.stderr)
        self.assertFalse(output.exists())


unittest.main(argv=["runner-identity-binding"], verbosity=1)
PY
