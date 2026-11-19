"""lockfile.py 的单元测试（仅依赖标准库）。"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "lockfile.py"
LOCK = ROOT / "lock" / "nginx.lock.json"
VALID_SHA = "a" * 64


def run_lockfile(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        capture_output=True,
        text=True,
        check=False,
    )


class LockfileTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.workdir = Path(self.tmp.name)
        self.lock_copy = self.workdir / "nginx.lock.json"
        self.lock_copy.write_text(LOCK.read_text(encoding="utf-8"), encoding="utf-8")

    def test_summary_lists_all_components(self) -> None:
        result = run_lockfile("summary", str(self.lock_copy))
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ("nginx", "openssl", "pcre2", "zlib"):
            self.assertIn(f"- {name}:", result.stdout)

    def test_export_locked_version_keeps_sha(self) -> None:
        result = run_lockfile("export", str(self.lock_copy))
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = [line.split("|") for line in result.stdout.splitlines() if line]
        self.assertTrue(rows)
        nginx_rows = [row for row in rows if row[0] == "nginx"]
        self.assertEqual(len(nginx_rows), 1)
        self.assertEqual(nginx_rows[0][1], "1.30.7")
        self.assertRegex(nginx_rows[0][2], r"^[0-9a-f]{64}$")

    def test_export_override_clears_sha_for_nginx(self) -> None:
        result = run_lockfile(
            "export", str(self.lock_copy), "--nginx-version", "1.31.9"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        nginx_row = next(
            row.split("|")
            for row in result.stdout.splitlines()
            if row.startswith("nginx|")
        )
        self.assertEqual(nginx_row[1], "1.31.9")
        self.assertEqual(nginx_row[2], "")
        # 依赖组件保持锁定
        openssl_row = next(
            row.split("|")
            for row in result.stdout.splitlines()
            if row.startswith("openssl|")
        )
        self.assertRegex(openssl_row[2], r"^[0-9a-f]{64}$")

    def test_set_updates_version_and_sha(self) -> None:
        out = self.workdir / "updated.json"
        result = run_lockfile(
            "set",
            str(self.lock_copy),
            "--component",
            "nginx",
            "--version",
            "1.30.8",
            "--sha256",
            VALID_SHA,
            "--out",
            str(out),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(data["components"]["nginx"]["version"], "1.30.8")
        self.assertEqual(data["components"]["nginx"]["sha256"], VALID_SHA)
        self.assertIn("updated_at", data)

    def test_set_rejects_invalid_sha(self) -> None:
        out = self.workdir / "bad.json"
        result = run_lockfile(
            "set",
            str(self.lock_copy),
            "--component",
            "nginx",
            "--sha256",
            "not-a-hash",
            "--out",
            str(out),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(out.exists())

    def test_set_accepts_two_segment_component_version(self) -> None:
        out = self.workdir / "zlib.json"
        result = run_lockfile(
            "set",
            str(self.lock_copy),
            "--component",
            "zlib",
            "--version",
            "1.4",
            "--sha256",
            VALID_SHA,
            "--out",
            str(out),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(data["components"]["zlib"]["version"], "1.4")

    def test_set_rejects_two_segment_nginx_version(self) -> None:
        out = self.workdir / "nginx-bad.json"
        result = run_lockfile(
            "set",
            str(self.lock_copy),
            "--component",
            "nginx",
            "--version",
            "1.30",
            "--sha256",
            VALID_SHA,
            "--out",
            str(out),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(out.exists())

    def test_get_unknown_component_fails(self) -> None:
        result = run_lockfile("get", str(self.lock_copy), "unknown", "version")
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
