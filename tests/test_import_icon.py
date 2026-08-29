#!/usr/bin/env python3
"""Security regression tests for the local icon importer."""

import binascii
import base64
import hashlib
import os
import pathlib
import stat
import struct
import subprocess
import tempfile
import unittest
import zlib

SCRIPT = pathlib.Path(__file__).parents[1] / "scripts" / "import-icon"
MAX_BYTES = 128 * 1024


def png_chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", binascii.crc32(kind + data) & 0xFFFFFFFF)


def valid_png():
    header = struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)
    pixels = zlib.compress(b"\x00\x00\x00\x00\xff")
    return b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", header) + png_chunk(b"IDAT", pixels) + png_chunk(b"IEND", b"")


class ImportIconTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.assets = self.root / "assets"
        self.destination = self.root / "icons"
        self.assets.mkdir()

    def tearDown(self):
        self.temporary.cleanup()

    def run_import(self, source, destination=None):
        return subprocess.run(
            [SCRIPT, str(source), str(self.assets), str(destination or self.destination)],
            text=True, capture_output=True, timeout=3, check=False
        )

    def run_data_url(self, source, timeout=3):
        return subprocess.run(
            [SCRIPT, "--data-url", str(source)],
            text=True, capture_output=True, timeout=timeout, check=False
        )

    def assert_rejected(self, source, message=None, destination=None):
        result = self.run_import(source, destination)
        self.assertNotEqual(result.returncode, 0)
        if message:
            self.assertIn(message, result.stderr)

    def test_valid_png_is_content_addressed_and_private(self):
        data = valid_png()
        source = self.root / "icon.png"
        source.write_bytes(data)
        result = self.run_import(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        imported = pathlib.Path(result.stdout.strip())
        self.assertEqual(imported.name, hashlib.sha256(data).hexdigest() + ".png")
        self.assertEqual(imported.read_bytes(), data)
        self.assertEqual(stat.S_IMODE(self.destination.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(imported.stat().st_mode), 0o600)
        data_url = self.run_data_url(imported)
        self.assertEqual(data_url.returncode, 0, data_url.stderr)
        prefix, encoded = data_url.stdout.strip().split(",", 1)
        self.assertEqual(prefix, "data:image/png;base64")
        self.assertEqual(base64.b64decode(encoded), data)

    def test_relative_asset_and_deduplication(self):
        source = self.assets / "icon.png"
        source.write_bytes(valid_png())
        first = self.run_import("icon.png")
        second = self.run_import("icon.png")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.stdout, first.stdout)

    def test_remote_sources_are_rejected(self):
        self.assert_rejected("https://example.com/icon.png", "Remote icons")
        self.assert_rejected("file://server/share/icon.png", "Only local file URLs")

    def test_oversized_and_malformed_pngs_are_rejected(self):
        oversized = self.root / "oversized.png"
        with oversized.open("wb") as output:
            output.truncate(MAX_BYTES + 1)
        self.assert_rejected(oversized, "no larger than 128 KiB")
        malformed = self.root / "malformed.png"
        malformed.write_bytes(valid_png()[:-4])
        self.assert_rejected(malformed, "valid PNG")

    def test_fifo_source_is_rejected_without_blocking(self):
        fifo = self.root / "icon.png"
        os.mkfifo(fifo)
        self.assert_rejected(fifo, "regular file")

    def test_safe_svg_is_accepted(self):
        source = self.root / "icon.svg"
        source.write_text('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><path d="M0 0h10v10z"/></svg>')
        result = self.run_import(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.strip().endswith(".svg"))

    def test_active_and_external_svg_content_is_rejected(self):
        cases = [
            '<svg xmlns="http://www.w3.org/2000/svg"><script>1</script></svg>',
            '<svg xmlns="http://www.w3.org/2000/svg"><image href="data:image/png;base64,AA=="/></svg>',
            '<svg xmlns="http://www.w3.org/2000/svg"><use href="https://example.com/a.svg#x"/></svg>',
            '<svg xmlns="http://www.w3.org/2000/svg"><use href="other.svg#x"/></svg>',
            '<!DOCTYPE svg [<!ENTITY x "x">]><svg xmlns="http://www.w3.org/2000/svg">&x;</svg>',
            ' ' * 5000 + '<!DOCTYPE svg><svg xmlns="http://www.w3.org/2000/svg"/>',
            '<?xml-stylesheet href="theme.css"?><svg xmlns="http://www.w3.org/2000/svg"/>',
            '<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"/>',
            '<svg xmlns="http://www.w3.org/2000/svg"><style>@import "theme.css";</style></svg>',
            '<svg xmlns="http://www.w3.org/2000/svg"><path style="fill:url(\'data:image/png;base64,AA==\')"/></svg>',
            '<svg xmlns="http://www.w3.org/2000/svg"><use id="loop" href="#loop"/></svg>',
            '<svg xmlns="http://www.w3.org/2000/svg"><filter id="f"><feGaussianBlur stdDeviation="999"/></filter></svg>',
            '<svg xmlns="http://www.w3.org/2000/svg"><animate attributeName="opacity" repeatCount="indefinite"/></svg>',
        ]
        for index, content in enumerate(cases):
            with self.subTest(index=index):
                source = self.root / f"unsafe-{index}.svg"
                source.write_text(content)
                self.assert_rejected(source)

    def test_symlink_destination_is_rejected(self):
        real = self.root / "real"
        real.mkdir()
        linked = self.root / "linked"
        linked.symlink_to(real, target_is_directory=True)
        source = self.root / "icon.png"
        source.write_bytes(valid_png())
        self.assert_rejected(source, "real directory", linked)

    def test_managed_reader_rejects_symlink_and_content_mismatch(self):
        data = valid_png()
        actual = self.root / "actual.png"
        actual.write_bytes(data)
        linked = self.root / (hashlib.sha256(data).hexdigest() + ".png")
        linked.symlink_to(actual)
        self.assertNotEqual(self.run_data_url(linked).returncode, 0)

        mismatched = self.root / ("0" * 64 + ".png")
        mismatched.write_bytes(data)
        result = self.run_data_url(mismatched)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("content-addressed name", result.stderr)

    def test_existing_destination_symlink_is_replaced_not_followed(self):
        data = valid_png()
        digest_name = hashlib.sha256(data).hexdigest() + ".png"
        target = self.root / "target"
        target.write_bytes(b"do not modify")
        self.destination.mkdir()
        (self.destination / digest_name).symlink_to(target)
        source = self.root / "source.png"
        source.write_bytes(data)
        result = self.run_import(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(target.read_bytes(), b"do not modify")
        self.assertFalse((self.destination / digest_name).is_symlink())
        self.assertEqual((self.destination / digest_name).read_bytes(), data)


if __name__ == "__main__":
    unittest.main()
