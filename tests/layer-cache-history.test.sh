#!/usr/bin/env bash
set -euo pipefail
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PYTHONDONTWRITEBYTECODE=1 python3 - "$repository_root" <<'PY'
import contextlib
import copy
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("layer_history", Path(sys.argv[1]) / "tests/integration/compare-dependency-layers.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def fixture():
    history = [
        {"CreatedBy": "/bin/sh -c #(nop) ADD file:base in /", "Size": "4096"},
        {"CreatedBy": "RUN true # buildkit", "Size": "0"},
        {"CreatedBy": "WORKDIR /workspace", "Size": "4096"},
        {"CreatedBy": "ENV EXAMPLE=value", "Size": "0"},
    ]
    history += [{"CreatedBy": f"COPY --chown=1001:123 {path} {path} # buildkit", "Size": "1024"}
                for path in module.DEPENDENCY_PATHS]
    history.append({"CreatedBy": 'CMD ["/bin/bash"]', "Size": "0"})
    history.reverse()
    image_id = "sha256:" + "a" * 64
    for index, row in enumerate(history):
        row["ID"] = image_id if index == 0 else "<missing>"
    inspect = {"Id": image_id, "RootFS": {"Type": "layers", "Layers": [f"sha256:{index:064x}" for index in range(8)]}}
    return inspect, history


class HistoryTests(unittest.TestCase):
    def test_maps_physical_copy_layers_including_zero_byte_run(self):
        inspect, history = fixture()
        rows = module.dependency_layers(inspect, history)
        self.assertEqual([row["layer_index"] for row in rows], [3, 4, 5, 6, 7])
        self.assertEqual([row["diff_id"] for row in rows], inspect["RootFS"]["Layers"][3:])

    def test_rejects_ambiguous_or_mismatched_history(self):
        mutations = [
            lambda image, rows: image["RootFS"]["Layers"].pop(),
            lambda image, rows: rows[0].update(ID="sha256:" + "b" * 64),
            lambda image, rows: rows[0].update(Size="4096"),
            lambda image, rows: rows[0].update(CreatedBy="UNKNOWN value"),
            lambda image, rows: next(row for row in rows if row["CreatedBy"].startswith("WORKDIR")).update(Size="0"),
            lambda image, rows: next(row for row in rows if row["CreatedBy"].startswith("COPY")).update(CreatedBy="COPY /unrelated /unrelated # buildkit"),
        ]
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                inspect, history = fixture()
                mutation(inspect, history)
                with self.assertRaises(ValueError):
                    module.dependency_layers(inspect, history)

    def test_requires_equal_layers_and_completed_export_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            source = "1" * 40
            runner = "2" * 40
            (directory / "inputs.json").write_text(json.dumps({"synthetic_fixture_revision": source,
                "runner_images_revision": runner, "platform": "linux/arm64"}))
            for phase, backend in (("dependency-change", "vulkan"), ("cpu-switch", "cpu")):
                inspect, history = fixture()
                inspect.update(Os="linux", Architecture="arm64", Config={
                    "Labels": {"io.mesh-llm.source.revision": source, "io.mesh-llm.runner-images.revision": runner},
                    "Env": [f"MESH_RUNNER_BACKEND={backend}"]})
                (directory / f"{phase}-inspect.json").write_text(json.dumps([inspect]))
                (directory / f"{phase}-history.jsonl").write_text("\n".join(json.dumps(row) for row in history))
                (directory / f"{phase}.log").write_text(f"#35 exporting manifest list {inspect['Id']} done\n")
            with contextlib.redirect_stdout(io.StringIO()):
                module.compare(directory)
            (directory / "cpu-switch.log").write_text(f"#35 exporting config {inspect['Id']} 0.0s done\n")
            with contextlib.redirect_stdout(io.StringIO()):
                module.compare(directory)
            good_inspect = copy.deepcopy(inspect)
            inspect["RootFS"]["Layers"][3] = "sha256:" + "f" * 64
            (directory / "cpu-switch-inspect.json").write_text(json.dumps([inspect]))
            with self.assertRaisesRegex(ValueError, "dependency layer changed"):
                module.compare(directory)
            (directory / "cpu-switch-inspect.json").write_text(json.dumps([good_inspect]))
            (directory / "cpu-switch.log").write_text("#35 exporting layers done\n")
            with self.assertRaisesRegex(ValueError, "completed build exports"):
                module.compare(directory)


unittest.main(argv=["layer-cache-history"], verbosity=1)
PY
