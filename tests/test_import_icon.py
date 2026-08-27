#!/usr/bin/env python3
"""Security regression tests for the local icon importer."""

import binascii
import hashlib
import pathlib
import stat
import struct
import subprocess
import tempfile
import unittest
import zlib

SCRIPT = pathlib.Path(__file__).parents[1] / "scripts" / "import-icon"


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
            output.truncate(2 * 1024 * 1024 + 1)
        self.assert_rejected(oversized, "no larger than 2 MiB")
        malformed = self.root / "malformed.png"
        malformed.write_bytes(valid_png()[:-4])
        self.assert_rejected(malformed, "valid PNG")

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


if __name__ == "__main__":
    unittest.main()
