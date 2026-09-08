"""Host-only receipt and invocation capture tests using independently bound OCI fixtures."""

import importlib.util
import os
from pathlib import Path
import sys
import time

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("identity_fixtures", Path(__file__).with_name("runner_identity.py"))
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)
globals().update({name: value for name, value in vars(fixtures).items() if not name.startswith("_")})
spec = importlib.util.spec_from_file_location("metrics", repository / "scripts/runner-build-metrics.py")
metrics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metrics)


def environment():
    return {"METRICS_REPOSITORY": "Mesh-LLM/mesh-llm-runner-images",
            "METRICS_WORKFLOW_PATH": ".github/workflows/build-and-push.yml",
            "METRICS_RUN_ID": "123", "METRICS_RUN_ATTEMPT": "1", "METRICS_HEAD_SHA": "a" * 40,
            "METRICS_RUNNER_IMAGES_SHA": RUNNER, "METRICS_MESH_LLM_SHA": SOURCE,
            "METRICS_ENVIRONMENT": "public", "METRICS_BACKEND_ID": "cpu", "METRICS_PLATFORM": "linux/amd64",
            "METRICS_OUTCOME": "success", "METRICS_BUILD_ID": "production-build", "METRICS_PROJECT_ID": "mzm95zcv7p",
            "DEPOT_PROJECT_ID": "mzm95zcv7p", "METRICS_STARTED_AT": "100", "METRICS_CONTEXT_BYTES": "0",
            "METRICS_CONTEXT_FILES": "0", "METRICS_VERIFIER_SHA": VERIFIER}


class MetricsTests(IdentityFixtures):
    def metadata(self):
        return raw({"depot.build": {"buildID": "verification-build", "projectID": "mzm95zcv7p"}})

    def invocation(self, **kwargs):
        return metrics.create_receipt("verification", environment(), self.metadata(),
            state={"outcome": "success", "wrapper_elapsed_seconds": 2.5}, **kwargs)

    def test_roles_and_head_are_separate(self):
        production = metrics.create_receipt("production", environment(), now=103)
        verification = self.invocation(identity_raw=raw(self.bind(self.fixture())))
        self.assertNotEqual(production["depot"]["build_id"], verification["depot"]["build_id"])
        self.assertNotEqual(production["identity"]["head_sha"], production["identity"]["runner_images_sha"])
        self.assertEqual(production["wrapper_elapsed_seconds"], 3)
        self.assertEqual(production["context"]["content_bytes"], 0)
        self.assertIsNone(production["depot"]["execution_seconds"])
        self.assertIsNone(verification["context"]["transfer_seconds"])
        self.assertIsNotNone(verification["verification"])

    def test_binding_failure_keeps_successful_invocation_and_null_identity(self):
        result = self.invocation()
        self.assertEqual(result["outcome"], "success")
        self.assertIsNone(result["verification"])

    def test_failed_skipped_cancelled_and_preinvocation_unknown(self):
        for outcome in ("failure", "skipped", "cancelled"):
            env = {**environment(), "METRICS_OUTCOME": outcome, "METRICS_BUILD_ID": "", "METRICS_PROJECT_ID": "",
                   "METRICS_STARTED_AT": "", "METRICS_CONTEXT_BYTES": "", "METRICS_CONTEXT_FILES": ""}
            result = metrics.create_receipt("production", env)
            self.assertEqual(result["outcome"], outcome)
            self.assertIsNone(result["depot"]["build_id"])
            self.assertIsNone(result["wrapper_elapsed_seconds"])
            self.assertIsNone(result["context"]["content_bytes"])
        result = metrics.create_receipt("verification", {**environment(), "METRICS_OUTCOME": "failure"})
        self.assertEqual(result["outcome"], "unknown")
        result = metrics.create_receipt("verification", environment(), state={"outcome": "failure", "wrapper_elapsed_seconds": 1})
        self.assertEqual(result["outcome"], "failure")

    def test_workflow_skipped_verification_has_no_invocation_measurements(self):
        env = {key: value for key, value in environment().items() if key not in {
            "METRICS_BUILD_ID", "METRICS_PROJECT_ID", "METRICS_STARTED_AT", "METRICS_CONTEXT_BYTES", "METRICS_CONTEXT_FILES"}}
        env["METRICS_OUTCOME"] = "skipped"
        result = metrics.create_receipt("verification", env)
        self.assertEqual(result["outcome"], "skipped")
        self.assertTrue(all(value is None for value in result["depot"].values()))
        self.assertTrue(all(value is None for value in result["context"].values()))
        for key in ("wrapper_elapsed_seconds", "verification", "cache_evidence"):
            self.assertIsNone(result[key])
        with self.assertRaisesRegex(ValueError, "skipped invocation"):
            metrics.create_receipt("verification", env, self.metadata())
        with self.assertRaisesRegex(ValueError, "skipped verification"):
            metrics.create_receipt("verification", {**env, "METRICS_CONTEXT_BYTES": "0", "METRICS_CONTEXT_FILES": "0"})

    def test_success_requires_actual_camelcase_ids_and_expected_project(self):
        for metadata in (None, raw({"depot.build": {"build_id": "b", "project_id": "p"}}),
                         raw({"depot.build": {"buildID": "b", "projectID": "wrong"}})):
            with self.assertRaises(ValueError):
                metrics.create_receipt("verification", environment(), metadata,
                    state={"outcome": "success", "wrapper_elapsed_seconds": 1})

    def test_source_family_platform_and_verifier_mismatch_fail(self):
        for mutate in (lambda r: r["runtime"]["source"].update(mesh_revision="f" * 40),
                       lambda r: r["runtime"]["family"].update(backend="web"),
                       lambda r: r["runtime"]["family"].update(cuda_series="12-9"),
                       lambda r: r["platform"].update(architecture="arm64"),
                       lambda r: r["runtime"]["verification"].update(verifier_revision="f" * 40),
                       lambda r: r.update(image="ghcr.io/other/image"),
                       lambda r: r.update(schema=True)):
            receipt = self.bind(self.fixture())
            mutate(receipt)
            with self.assertRaises(ValueError):
                self.invocation(identity_raw=raw(receipt))

    def test_layers_reuse_exact_identity_and_count_occurrences(self):
        receipt = self.bind(self.fixture())
        receipt["layers"].append(copy.deepcopy(receipt["layers"][0]))
        result = self.invocation(identity_raw=raw(receipt))["verification"]
        self.assertEqual(result["identity_receipt_sha256"], metrics.sha256(raw(receipt)))
        self.assertEqual(result["totals"]["layer_descriptor_bytes"], receipt["layers"][0]["size"] * 2)
        self.assertEqual(len(result["totals"]["distinct_layer_digests"]), 1)
        receipt["layers"][1]["size"] += 1
        with self.assertRaisesRegex(ValueError, "conflicting"):
            self.invocation(identity_raw=raw(receipt))

    def test_layer_overflow_boolean_and_compression_fail(self):
        for key, value in (("size", True), ("size", 2 ** 53), ("compression", "uncompressed")):
            receipt = self.bind(self.fixture())
            receipt["layers"][0][key] = value
            with self.assertRaises(ValueError):
                self.invocation(identity_raw=raw(receipt))

    def test_actual_rawjson_cold_and_warm(self):
        cold = metrics.cache_proof((Path(__file__).parent / "buildkit-progress/cold.jsonl").read_bytes())
        warm = metrics.cache_proof((Path(__file__).parent / "buildkit-progress/warm.jsonl").read_bytes())
        self.assertEqual(cold["cached_vertex_digests"], [])
        self.assertEqual(len(warm["cached_vertex_digests"]), 1)
        self.assertNotIn("hit_rate", warm)

    def test_actual_plain_warm(self):
        result = metrics.cache_proof((Path(__file__).parent / "buildkit-progress/warm.log").read_bytes(), "buildkit-plain-v1")
        self.assertEqual(result["cached_operations"], [4])
        self.assertNotIn("cached_vertex_digests", result)

    def test_plain_ignores_internal_and_output_but_rejects_conflicts(self):
        good = b"warning\n#1 [internal] resolve source\n#1 DONE 0.0s\n#1 CACHED\n#2 [stage 1/1] RUN echo x\n#2 0.1 #3 CACHED\n#2 CACHED\n"
        self.assertEqual(metrics.cache_proof(good, "buildkit-plain-v1")["cached_operations"], [2])
        bad = (b"#0 building x\n#0 building y\n", b"#1 [1/1] COPY a b\n#1 [1/1] RUN x\n",
               b"#1 [1/1] ADD a b\n#1 CACHED\n#1 DONE 0.0s\n", b"#1 CACHED\n#1 [1/1] RUN x\n")
        for value in bad:
            with self.assertRaises(ValueError):
                metrics.cache_proof(value, "buildkit-plain-v1")

    def test_rawjson_bad_types_truncation_flat_and_bounds_fail(self):
        for value in (b'{"id":"x","cached":true}\n', b'{"vertexes":',
                      b'{"vertexes":[{"digest":"sha256:' + b'a' * 64 + b'","cached":1}]}',
                      b'{"vertexes":{}}', b'{}', b' ' * 65537, b'\n' * 100001,
                      b'x' * (metrics.MAX_CACHE + 1)):
            with self.assertRaises((ValueError, UnicodeError)):
                metrics.cache_proof(value)

    def test_explicit_cache_requires_ids(self):
        with self.assertRaisesRegex(ValueError, "requires invocation"):
            metrics.create_receipt("production", {**environment(), "METRICS_OUTCOME": "failure", "METRICS_BUILD_ID": ""},
                now=101, cache_raw=b"#1 [1/1] RUN x\n#1 CACHED\n", cache_format="buildkit-plain-v1")

    def test_cli_bundle_and_immutable_reimport(self):
        source = self.root / "identity.json"
        source.write_bytes(raw(self.bind(self.fixture())))
        metadata = self.root / "metadata.json"
        metadata.write_bytes(self.metadata())
        state = self.root / "state.json"
        state.write_text('{"outcome":"success","wrapper_elapsed_seconds":2}')
        bundle = self.root / "bundle"
        command = [sys.executable, "-B", str(repository / "scripts/runner-build-metrics.py"), "--role", "verification",
                   "--output", str(bundle), "--metadata", str(metadata), "--state", str(state), "--identity", str(source),
                   "--cache-log", str(Path(__file__).parent / "buildkit-progress/warm.log"), "--cache-format", "buildkit-plain-v1"]
        result = subprocess.run(command, env={**os.environ, **environment()}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual({p.name for p in bundle.iterdir()}, {"receipt.json", "identity.json", "cache.log"})
        self.assertEqual((bundle / "identity.json").read_bytes(), source.read_bytes())
        again = subprocess.run(command, env={**os.environ, **environment()}, capture_output=True, text=True)
        self.assertNotEqual(again.returncode, 0)

    def test_capture_refuses_existing_outputs_before_command(self):
        for name in ("cache.log", "state.json"):
            root = self.root / name.replace(".", "-")
            root.mkdir()
            (root / name).write_text("existing")
            marker = root / "command-started"
            command = [sys.executable, "-B", str(repository / "scripts/capture-build-invocation.py"),
                       "--state", str(root / "state.json"), "--log", str(root / "cache.log"), "--",
                       sys.executable, "-c", f"from pathlib import Path; Path({str(marker)!r}).touch()"]
            result = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(marker.exists())

    def test_snapshot_elapsed_does_not_include_later_artifact_work(self):
        result = metrics.create_receipt("production", {**environment(), "METRICS_ELAPSED_SECONDS": "3"}, now=100000)
        self.assertEqual(result["wrapper_elapsed_seconds"], 3)

    def test_capture_cancellation_reaps_the_child(self):
        pid_file = self.root / "child-pid"
        command = [sys.executable, "-B", str(repository / "scripts/capture-build-invocation.py"),
                   "--state", str(self.root / "state.json"), "--log", str(self.root / "cache.log"), "--",
                   sys.executable, "-c", f"import os,time; from pathlib import Path; Path({str(pid_file)!r}).write_text(str(os.getpid())); time.sleep(60)"]
        process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 5
            while not pid_file.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(pid_file.exists(), "child did not start")
            child = int(pid_file.read_text())
            process.terminate()
            process.communicate(timeout=7)
            self.assertNotEqual(process.returncode, 0)
            with self.assertRaises(ProcessLookupError):
                os.kill(child, 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()

    def test_capture_retains_exit_status_and_bounded_output(self):
        for status, size in ((0, 100), (9, metrics.MAX_CACHE + 100)):
            root = self.root / str(status)
            command = [sys.executable, "-B", str(repository / "scripts/capture-build-invocation.py"),
                       "--state", str(root / "state.json"), "--log", str(root / "cache.log"), "--",
                       sys.executable, "-c", f"import sys; sys.stdout.write('x'*{size}); sys.exit({status})"]
            result = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            self.assertEqual(result.returncode, status, result.stderr)
            self.assertEqual((root / "cache.log").stat().st_size, min(size, metrics.MAX_CACHE + 1))
            state = json.loads((root / "state.json").read_text())
            self.assertEqual(state["outcome"], "success" if status == 0 else "failure")
            self.assertGreaterEqual(state["wrapper_elapsed_seconds"], 0)


if __name__ == "__main__":
    unittest.main()
