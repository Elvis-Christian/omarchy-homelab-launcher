#!/usr/bin/env python3
"""Regression tests for bounded, descriptor-safe services storage."""

import json
import os
import pathlib
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).parents[1] / "scripts" / "services-store"
MAX_BYTES = 512 * 1024


class ServicesStoreTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.data = self.root / "data"
        self.data.mkdir()
        self.services = self.data / "services.json"

    def tearDown(self):
        self.temporary.cleanup()

    def run_store(self, operation, path=None, stdin=None, timeout=2):
        return subprocess.run(
            [SCRIPT, operation, str(path or self.services)],
            input=stdin,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )

    def test_missing_file_reads_as_empty_configuration(self):
        self.data.rmdir()
        result = self.run_store("read")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"services": []})
        self.assertTrue(self.data.is_dir())
        self.assertEqual(self.data.stat().st_mode & 0o777, 0o700)

    def test_regular_file_round_trip_is_atomic(self):
        payload = json.dumps({"services": [{"name": "NAS", "url": "https://nas.test", "icon": "nas.svg"}]})
        written = self.run_store("write", stdin=payload + "\n")
        self.assertEqual(written.returncode, 0, written.stderr)
        loaded = self.run_store("read")
        self.assertEqual(loaded.returncode, 0, loaded.stderr)
        self.assertEqual(json.loads(loaded.stdout), json.loads(payload))
        self.assertEqual(list(self.data.glob(".services-*")), [])

    def test_oversized_file_is_rejected_before_reading(self):
        with self.services.open("wb") as output:
            output.truncate(MAX_BYTES + 1)
        result = self.run_store("read")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("too large", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_fifo_is_rejected_without_blocking(self):
        os.mkfifo(self.services)
        result = self.run_store("read", timeout=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("regular file", result.stderr)

    def test_file_symlink_is_rejected(self):
        target = self.root / "target.json"
        target.write_text('{"services":[]}')
        self.services.symlink_to(target)
        result = self.run_store("read")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symlink or pipe", result.stderr)

    def test_parent_symlink_is_rejected(self):
        real = self.root / "real"
        real.mkdir()
        (real / "services.json").write_text('{"services":[]}')
        linked = self.root / "linked"
        linked.symlink_to(real, target_is_directory=True)
        result = self.run_store("read", linked / "services.json")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("real directory", result.stderr)

    def test_write_rejects_oversized_or_invalid_input(self):
        oversized = '{"services":["' + "x" * MAX_BYTES + '"]}\n'
        self.assertNotEqual(self.run_store("write", stdin=oversized).returncode, 0)
        self.assertNotEqual(self.run_store("write", stdin="not json\n").returncode, 0)

    def test_qml_fileview_is_watch_only(self):
        qml = (SCRIPT.parents[1] / "Launcher.qml").read_text()
        file_view = qml[qml.index("FileView {"):qml.index("PanelWindow {")]
        self.assertIn("preload: false", file_view)
        self.assertNotIn("text()", file_view)
        self.assertNotIn("reload()", file_view)
        self.assertNotIn("onLoaded", file_view)

    def test_qml_never_decodes_managed_icons_from_mutable_paths(self):
        qml = (SCRIPT.parents[1] / "Launcher.qml").read_text()
        self.assertIn('"--data-url", activeManagedIcon', qml)
        self.assertIn("managedIconReference(icon)", qml)
        self.assertNotIn("packagedIconReference", qml)
        self.assertNotIn('return "file://" + assetsDir', qml)
        self.assertNotIn('if (icon.charAt(0) === "/") return "file://" + icon', qml)
        self.assertIn("readonly property int maxServices: 50", qml)
        self.assertIn("output.length <= 180000", qml)


if __name__ == "__main__":
    unittest.main()
