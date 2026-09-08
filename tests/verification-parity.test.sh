#!/usr/bin/env bash
set -euo pipefail
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
python3 -B - "$repository_root" <<'PY'
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

repository = Path(sys.argv[1])
SOURCE, RUNNER, VERIFIER = "1" * 40, "2" * 40, "3" * 40


class VerificationParityTests(unittest.TestCase):
    def test_every_docker_caller_preserves_independent_seven_arguments(self):
        catalog = json.loads((repository / "config/runner-image-families.json").read_text())
        for backend in catalog["backends"]:
            for environment in backend.get("environments", catalog["environments"]):
                for staged in (False, True):
                    filename = "Dockerfile.verify" if staged else backend.get("dockerfile", "Dockerfile")
                    target = "verified" if staged else environment + "-test"
                    source = (repository / filename).read_text()
                    blocks = re.split(r"(?=^FROM )", source, flags=re.M)
                    block = next(block for block in blocks if block.splitlines()[0].endswith(" AS " + target))
                    for name in ("verify-runner-candidate.sh", "verify-runner-image.sh", "collect-runner-identity.py",
                                 "tool-pins.json", "cache-policy.json", "python-requirements.lock", "playwright-pin.txt"):
                        self.assertTrue(any(name in line and line.endswith(" /opt/mesh-runner-verification/")
                                            for line in block.splitlines() if line.startswith("COPY ")))
                    self.assertIn("ARG VERIFIER_REVISION", block)
                    run = block.split("RUN --network=none ", 1)[1].strip()
                    self.assertNotIn("\nRUN ", run)
                    report = self.root / "docker-caller.json"
                    run = run.replace("/tmp/mesh-runner-identity.json", str(report))
                    run = run.replace("/opt/mesh-runner-verification/playwright-pin.txt", str(repository / "config/playwright-pin.txt"))
                    run = run.replace("bash /opt/mesh-runner-verification/verify-runner-candidate.sh", "fixture")
                    program = "fixture() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' \"$@\"; }\n" + run
                    values = {**os.environ, "VERIFIER_REVISION": VERIFIER, "CANDIDATE_IMAGE": "fixture:local@sha256:" + "a" * 64}
                    mesh = {"ENVIRONMENT": environment, "BACKEND": backend["name"], "MESH_REVISION": SOURCE,
                            "RUNNER_IMAGES_REVISION": RUNNER, "CUDA_SERIES": backend["cuda_series"] or "none",
                            "ROCM_VERSION": backend["rocm_version"] or "none"}
                    values.update({"EXPECTED_" + key: value for key, value in mesh.items()})
                    values.update({"BACKEND": mesh["BACKEND"], "MESH_LLM_REVISION": SOURCE,
                                   "RUNNER_IMAGES_REVISION": RUNNER, "CUDA_SERIES": mesh["CUDA_SERIES"], "ROCM_VERSION": mesh["ROCM_VERSION"]})
                    with self.subTest(file=filename, target=target, backend=backend["id"]):
                        subprocess.run(["bash", "-euo", "pipefail", "-c", program], env=values, check=True, capture_output=True, text=True)
                        self.assertEqual(json.loads(report.read_text()), ["--expected-directory", "/opt/mesh-runner-verification",
                            "--verifier-revision", VERIFIER, environment, backend["name"], SOURCE,
                            mesh["CUDA_SERIES"], mesh["ROCM_VERSION"], RUNNER,
                            self.pin if backend["name"] in {"web", "browser"} else "none"])

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.expected = self.root / "independent inputs"
        self.expected.mkdir()
        for name in ("tool-pins.json", "cache-policy.json", "python-requirements.lock", "playwright-pin.txt"):
            shutil.copyfile(repository / "config" / name, self.expected / name)
        self.pin = (self.expected / "playwright-pin.txt").read_text().strip()
        self.environment = {**os.environ, "FIXTURE_LOG": str(self.root / "calls.jsonl"), "FIXTURE_MODE": "success"}
        # Relocate only the absolute Actions paths. The complete real wrapper,
        # including its CLI, subprocess handling and JSON checks, is executed.
        text = (repository / "scripts/verify-runner-candidate.sh").read_text()
        for path in ("/home/runner/externals", "/__e"):
            text = text.replace('"' + path + '"', repr(str(self.root) + path))
        self.wrapper = self.root / "wrapper.sh"
        self.wrapper.write_text(text)
        (self.expected / "verify-runner-image.sh").write_text('''#!/usr/bin/env bash
set -euo pipefail
python3 -B - "$@" <<'HEALTH'
import json,os,sys
with open(os.environ['FIXTURE_LOG'], 'a') as stream:
    stream.write(json.dumps(['trusted-health', *sys.argv[1:]]) + '\\n')
print('fixture health stdout')
print('fixture health stderr', file=sys.stderr)
raise SystemExit(17 if os.environ['FIXTURE_MODE'] == 'health-failure' else 0)
HEALTH
''')
        # Preflight uses the actual collector's policy reader. Collection is a
        # controlled subprocess fixture; collector behavior has its own suite.
        (self.expected / "collect-runner-identity.py").write_text(f'''
import importlib.util,json,os,sys
from pathlib import Path
spec = importlib.util.spec_from_file_location('real_identity', {str(repository / "scripts/collect-runner-identity.py")!r})
real = importlib.util.module_from_spec(spec)
spec.loader.exec_module(real)
read_policy, exact_keys, digest_json = real.read_policy, real.exact_keys, real.digest_json
if __name__ == '__main__':
    arguments = sys.argv[1:]
    with open(os.environ['FIXTURE_LOG'], 'a') as stream:
        stream.write(json.dumps(['collector', *arguments]) + '\\n')
    environment,backend,mesh,cuda,rocm,runner,playwright = arguments[-7:]
    verifier = arguments[arguments.index('--verifier-revision') + 1]
    directory = Path(arguments[arguments.index('--expected-directory') + 1])
    pins,policy = read_policy(directory)
    report = {{'schema':1,'type':'mesh-llm-runner-runtime-identity',
      'platform':{{'os':'linux','architecture':'amd64'}},
      'family':{{'environment':environment,'backend':backend,'cuda_series':None if cuda=='none' else cuda,'rocm_version':None if rocm=='none' else rocm}},
      'source':{{'mesh_revision':mesh,'runner_images_revision':runner}},
      'verification':{{'verifier_revision':verifier,'tool_pins_sha256':digest_json(pins),'cache_policy_sha256':digest_json(policy)}},
      'expected_tools':{{}},'tools':{{}},'dependencies':{{}},'cache':{{}}}}
    mode = os.environ['FIXTURE_MODE']
    if mode == 'collector-failure':
        print('{{"partial":true')
        print('fixture collector failed',file=sys.stderr)
        raise SystemExit(23)
    if mode == 'invalid-json':
        print('unexpected log before JSON')
    if mode == 'wrong-type': report['type']='other-report'
    if mode == 'wrong-schema': report['schema']=True
    if mode == 'missing-field': del report['cache']
    if mode == 'wrong-source': report['source']['mesh_revision']='a'*40
    if mode == 'wrong-verifier': report['verification']['verifier_revision']='a'*40
    if mode == 'wrong-pins': report['verification']['tool_pins_sha256']='sha256:'+'a'*64
    print(json.dumps(report))
''')
        self.node_paths = []
        for major in (20, 24):
            for prefix in ("home/runner/externals", "__e"):
                path = self.root / prefix / f"node{major}/bin/node"
                path.parent.mkdir(parents=True)
                path.write_text(f'''#!/usr/bin/env python3
import json,os,sys
with open(os.environ['FIXTURE_LOG'], 'a') as stream:
    stream.write(json.dumps(['node', sys.argv[0], *sys.argv[1:]]) + '\\n')
assert sys.argv[1] == '-e' and '!== "{major}"' in sys.argv[2]
raise SystemExit(29 if os.environ.get('FIXTURE_FAIL_NODE') == sys.argv[0] else 0)
''')
                path.chmod(0o755)
                self.node_paths.append(path)
        # A candidate-supplied helper must never substitute for the trusted one.
        fake_bin = self.root / "bin"
        fake_bin.mkdir()
        baked = fake_bin / "verify-runner-image"
        baked.write_text("#!/bin/sh\necho candidate-helper-was-used >&2\nexit 93\n")
        baked.chmod(0o755)
        self.environment["PATH"] = str(fake_bin) + os.pathsep + self.environment["PATH"]

    def arguments(self, backend="cpu", environment="public"):
        return ["--expected-directory", str(self.expected), "--verifier-revision", VERIFIER,
                environment, backend, SOURCE, "12-9" if backend == "cuda" else "none",
                "7.2.3" if backend == "rocm" else "none", RUNNER,
                self.pin if backend in {"web", "browser"} else "none"]

    def invoke(self, arguments=None, **environment):
        return subprocess.run(["bash", str(self.wrapper), *(self.arguments() if arguments is None else arguments)],
            capture_output=True, text=True, check=False, env={**self.environment, **environment})

    def calls(self):
        path = self.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def rejected(self, result, message=None):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.stdout, "", result.stdout)
        if message: self.assertIn(message, result.stderr)

    def test_all_backend_arguments_and_distinct_revisions_are_forwarded(self):
        for environment, backend in (("public", "cpu"), ("self-hosted", "cpu"), ("public", "vulkan"),
                ("self-hosted", "cuda"), ("public", "rocm"), ("public", "web"), ("public", "ui"), ("public", "browser")):
            with self.subTest(environment=environment, backend=backend):
                arguments = self.arguments(backend, environment)
                result = self.invoke(arguments)
                self.assertEqual(result.returncode, 0, result.stderr)
                report = json.loads(result.stdout)
                self.assertEqual(report["source"], {"mesh_revision": SOURCE, "runner_images_revision": RUNNER})
                self.assertEqual(report["verification"]["verifier_revision"], VERIFIER)
                self.assertEqual(self.calls()[-6], ["trusted-health", *arguments[-7:]])
                self.assertEqual(self.calls()[-1][-7:], arguments[-7:])

    def test_stdout_is_one_runtime_json_with_health_logs_on_stderr(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["type"], "mesh-llm-runner-runtime-identity")
        self.assertIn("fixture health stdout", result.stderr)
        self.assertIn("fixture health stderr", result.stderr)
        self.assertNotIn("candidate-helper-was-used", result.stderr)
        self.assertEqual([item[0] for item in self.calls()], ["trusted-health", "node", "node", "node", "node", "collector"])

    def test_missing_extra_and_unknown_arguments_fail_before_health(self):
        complete = self.arguments()
        cases = (complete[:-1], complete + ["extra"], complete[2:], complete[:2] + complete[4:],
                 ["--unknown", "value", *complete], ["--expected-directory"])
        for arguments in cases:
            with self.subTest(arguments=arguments):
                self.rejected(self.invoke(arguments))
        self.assertEqual(self.calls(), [])

    def test_each_source_and_verifier_requires_full_lowercase_sha(self):
        for index in (3, 6, 9):
            for value in ("", "main", "A" * 40, "1" * 39):
                with self.subTest(index=index, value=value):
                    arguments = self.arguments()
                    arguments[index] = value
                    self.rejected(self.invoke(arguments), "full lowercase Git SHAs")
        self.assertEqual(self.calls(), [])

    def test_family_and_version_arguments_fail_before_health(self):
        for index, value in ((4, "invalid"), (5, "unknown"), (7, "12-9"), (8, "7.2.3"), (10, self.pin)):
            arguments = self.arguments()
            arguments[index] = value
            self.rejected(self.invoke(arguments))
        self.rejected(self.invoke(self.arguments("browser", "self-hosted")), "unsupported browser/UI")
        arguments = self.arguments("cuda")
        arguments[7] = "12.9"
        self.rejected(self.invoke(arguments), "CUDA")
        self.assertEqual(self.calls(), [])

    def test_browser_expectation_must_match_independent_pin(self):
        for backend in ("web", "browser"):
            arguments = self.arguments(backend)
            for value in ("none", "9.9.9", ""):
                arguments[-1] = value
                self.rejected(self.invoke(arguments), "independent pin")
        self.assertEqual(self.calls(), [])

    def test_independent_playwright_pin_files_cannot_disagree(self):
        (self.expected / "playwright-pin.txt").write_text("9.9.9\n")
        self.rejected(self.invoke(), "Playwright pin files disagree")
        self.assertEqual(self.calls(), [])

    def test_required_independent_inputs_cannot_fall_back_to_image_files(self):
        for name in ("verify-runner-image.sh", "collect-runner-identity.py", "tool-pins.json", "cache-policy.json",
                     "python-requirements.lock", "playwright-pin.txt"):
            with self.subTest(name=name):
                path = self.expected / name
                content = path.read_bytes()
                try:
                    path.unlink()
                    self.rejected(self.invoke(), "missing independent verification input")
                finally:
                    path.write_bytes(content)
        self.assertEqual(self.calls(), [])

    def test_invalid_trusted_pin_and_cache_schemas_fail_before_health(self):
        for name in ("tool-pins.json", "cache-policy.json"):
            path = self.expected / name
            content = path.read_bytes()
            try:
                path.write_text('{}\n')
                self.rejected(self.invoke(), "keys")
            finally:
                path.write_bytes(content)
        self.assertEqual(self.calls(), [])

    def test_trusted_health_failure_stops_before_node_and_collector(self):
        result = self.invoke(FIXTURE_MODE="health-failure")
        self.rejected(result)
        self.assertEqual(result.returncode, 17)
        self.assertEqual([item[0] for item in self.calls()], ["trusted-health"])

    def test_each_actions_node_path_must_execute(self):
        for path in self.node_paths:
            with self.subTest(path=path):
                result = self.invoke(FIXTURE_FAIL_NODE=str(path))
                self.rejected(result)
                self.assertEqual(result.returncode, 29)
        self.assertFalse(any(item[0] == "collector" for item in self.calls()))

    def test_missing_or_non_executable_actions_nodes_fail(self):
        for path in self.node_paths:
            path.chmod(0o644)
            try:
                self.rejected(self.invoke(), "missing executable Actions Node path")
            finally:
                path.chmod(0o755)
        self.node_paths[-1].unlink()
        self.rejected(self.invoke(), "missing executable Actions Node path")
        self.assertFalse(any(item[0] == "collector" for item in self.calls()))

    def test_failed_collector_cannot_emit_partial_success_json(self):
        result = self.invoke(FIXTURE_MODE="collector-failure")
        self.rejected(result, "fixture collector failed")
        self.assertEqual(result.returncode, 23)

    def test_malformed_or_mismatched_collector_report_is_not_published(self):
        for mode in ("invalid-json", "wrong-type", "wrong-schema", "missing-field", "wrong-source", "wrong-verifier", "wrong-pins"):
            with self.subTest(mode=mode):
                self.rejected(self.invoke(FIXTURE_MODE=mode), "runner candidate verification failed")


unittest.main(argv=["verification-parity"], verbosity=1)
PY
