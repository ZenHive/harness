"""Focused runner mechanics. Live Flutter cases live in flutter_verification_test.exs."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True

SPEC = importlib.util.spec_from_file_location('flutter_verify', Path(__file__).parents[2] / 'scripts/flutter-verify.py')
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class FlutterRunnerTest(unittest.TestCase):
    def test_missing_sdk_records_failed_check_and_evidence(self):
        with tempfile.TemporaryDirectory(dir=Path.cwd()) as root:
            root = Path(root)
            args = argparse.Namespace(app=root, worktree=root, attempt='reviewer-1', timeout=1)
            with patch.dict(os.environ, {'PATH': ''}):
                self.assertEqual(runner.verify(args), 1)
            report = json.loads((root / '.harness/evidence/reviewer-1/checks.json').read_text())
            self.assertFalse(report['prerequisites']['passed'])
            self.assertIn('Missing prerequisite: flutter', report['prerequisites']['output'])
            self.assertIn('.harness/evidence/reviewer-1/checks.json', report['prerequisites']['evidence'])

    def test_missing_kvm_names_prerequisite_before_starting_emulator(self):
        with patch.object(runner, 'require', return_value='/tool'), patch.object(runner.os, 'access', return_value=False):
            with self.assertRaisesRegex(runner.VerificationError, '/dev/kvm'):
                runner.android(Path.cwd(), {}, Path.cwd(), 1)

    def test_missing_image_names_prerequisite(self):
        with patch.object(runner, 'require', return_value='/tool'), patch.object(runner.os, 'access', return_value=True):
            with self.assertRaisesRegex(runner.VerificationError, 'HARNESS_ANDROID_IMAGE'):
                runner.android(Path.cwd(), {}, Path.cwd(), 1)

    def test_failed_tool_is_not_converted_to_success(self):
        with tempfile.TemporaryDirectory(dir=Path.cwd()) as root:
            log = Path(root) / 'tool.log'
            with self.assertRaisesRegex(runner.VerificationError, 'Exit 7'):
                runner.run([sys.executable, '-c', 'print("golden mismatch"); raise SystemExit(7)'],
                           root, os.environ.copy(), log, 3)
            self.assertIn('golden mismatch', log.read_text())

    def test_timeout_terminates_owned_process(self):
        with tempfile.TemporaryDirectory(dir=Path.cwd()) as root:
            log = Path(root) / 'timeout.log'
            with self.assertRaisesRegex(runner.VerificationError, 'Timeout'):
                runner.run([sys.executable, '-c', 'import os,time; print(os.getpid(), flush=True); time.sleep(60)'],
                           root, os.environ.copy(), log, 0.2)
            with self.assertRaises(ProcessLookupError):
                os.kill(int(log.read_text()), 0)


if __name__ == '__main__':
    unittest.main()
