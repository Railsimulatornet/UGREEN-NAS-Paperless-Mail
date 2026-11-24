"""Exercise export safety with a temporary directory and a fake Docker command."""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = [ROOT / language / "paperless-ngx/scripts/paperless-export_with_mail.sh"
           for language in ("de", "en")]


class HtmlEscapeTests(unittest.TestCase):
    def test_special_characters_are_text_in_both_bash_modes(self):
        for script in SCRIPTS:
            source = script.read_text()
            names = ["html_escape"]
            if re.search(r"(?m)^html_escape_nbsp\(\)", source):
                names.append("html_escape_nbsp")
            functions = "\n".join(re.search(
                rf"(?ms)^{name}\(\) \{{.*?^\}}", source).group()
                for name in names)
            for mode in ("-s", "-u"):
                for function, expected in (
                    ("html_escape", "&lt;tag attr=&quot;x&quot;&gt;&amp;&#39;"),
                    ("html_escape_nbsp", "&lt;tag&nbsp;attr=&quot;x&quot;&gt;&amp;&#39;"),
                ):
                    if function not in names:
                        continue
                    with self.subTest(script=script.relative_to(ROOT), mode=mode, function=function):
                        result = subprocess.run(
                            ["bash", "-c", f"shopt {mode} patsub_replacement 2>/dev/null || true\n"
                             f'{functions}\n{function} "$1"', "test", '<tag attr="x">&\''],
                            capture_output=True, text=True, timeout=5)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(result.stdout, expected)


class RetentionTests(unittest.TestCase):
    def run_export(self, script, keep, *, copy_fails=False):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        backup = root / "backups"
        backup.mkdir()
        fixture = root / "export.zip"
        with zipfile.ZipFile(fixture, "w") as archive:
            archive.writestr("manifest.json", "[]")
        for index in range(3):
            old = backup / f"paperless_export_2000010{index + 1}_000000.zip"
            old.write_bytes(fixture.read_bytes())
            os.utime(old, (946684800 + index, 946684800 + index))
        bin_dir = root / "bin"
        bin_dir.mkdir()
        audit = root / "docker-calls"
        fake = bin_dir / "docker"
        fake.write_text('''#!/bin/bash
printf '%s\\n' "$1" >> "$TEST_DOCKER_AUDIT"
case "$1" in
  ps) printf '%s\\n' test-paperless ;;
  exec)
    case "${*: -1}" in
      ls*) printf '%s\\n' /tmp/test-paperless-export/export.zip ;;
      *) exit 0 ;;
    esac ;;
  cp)
    [[ "$TEST_COPY_FAILS" == 0 ]] || exit 1
    cp -- "$TEST_ZIP_FIXTURE" "$3" ;;
  *) exit 97 ;;
esac
''')
        fake.chmod(0o755)
        empty_env = root / "empty.env"
        empty_env.write_text("")
        env = {
            "PATH": f"{bin_dir}:/usr/bin:/bin", "LANG": "C.UTF-8",
            "ENV_FILE": str(empty_env), "CONTAINER_NAME": "test-paperless",
            "HOST_BACKUP_DIR": str(backup), "CONTAINER_TMP_DIR": "/tmp/test-paperless-export",
            "PAPERLESS_EXPORT_LOGFILE": str(root / "export.log"), "KEEP_FILES": keep,
            "MAIL_ENABLED": "0", "MAIL_ON_SUCCESS": "0", "MAIL_ON_FAILURE": "0",
            "TEST_DOCKER_AUDIT": str(audit), "TEST_ZIP_FIXTURE": str(fixture),
            "TEST_COPY_FAILS": str(int(copy_fails)),
        }
        result = subprocess.run(["bash", str(script)], env=env, cwd=root,
                                capture_output=True, text=True, timeout=10)
        return result, sorted(p.name for p in backup.iterdir()), audit

    def test_invalid_retention_stops_before_docker_and_preserves_backups(self):
        for script in SCRIPTS:
            for keep in ("0", "000", "-1", "broken", "999999999999999999999999"):
                with self.subTest(script=script.relative_to(ROOT), keep=keep):
                    result, files, audit = self.run_export(script, keep)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(len(files), 3)
                    self.assertFalse(audit.exists(), "Invalid retention must stop before Docker")

    def test_positive_limit_keeps_new_export_and_newest_old_export(self):
        for script in SCRIPTS:
            with self.subTest(script=script.relative_to(ROOT)):
                result, files, _ = self.run_export(script, "2")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(len(files), 2)
                self.assertIn("paperless_export_20000103_000000.zip", files)
                self.assertTrue(any(not name.startswith("paperless_export_2000") for name in files))

    def test_leading_zero_is_decimal(self):
        for script in SCRIPTS:
            with self.subTest(script=script.relative_to(ROOT)):
                result, files, _ = self.run_export(script, "08")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(len(files), 4)
                self.assertNotIn("value too great for base", result.stderr)

    def test_failed_copy_never_prunes_existing_exports(self):
        for script in SCRIPTS:
            with self.subTest(script=script.relative_to(ROOT)):
                result, files, _ = self.run_export(script, "1", copy_fails=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(files), 3)


if __name__ == "__main__":
    unittest.main()
