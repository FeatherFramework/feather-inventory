"""Release metadata guards; no database or resource mutations."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('verify_version', Path(__file__).resolve().parents[1] / 'scripts/verify_version.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ReleaseVersionTest(unittest.TestCase):
    def check_version(self, version, manifest=None, tag=None):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'web').mkdir()
            (root / 'web/package.json').write_text(json.dumps({'version': version}))
            (root / 'fxmanifest.lua').write_text(manifest if manifest is not None else f"version '{version}'\n")
            return module.verify(root, tag)

    def test_matching_versions_and_tags(self):
        for version in ('0.11.1', '0.12.0-alpha.1', '1.0.0+build.2'):
            for tag in (None, version, 'v' + version):
                with self.subTest(version=version, tag=tag):
                    self.assertEqual(self.check_version(version, tag=tag), version)

    def test_mismatched_tag_or_manifest_refused(self):
        for kwargs in ({'tag': '0.11.0'}, {'tag': ''}, {'manifest': "version '0.11.0'"}, {'manifest': "-- version '0.11.1'"}, {'manifest': "version '0.11.1'\nversion '0.11.1'"}):
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                self.check_version('0.11.1', **kwargs)

    def test_invalid_versions_refused(self):
        for version in ('01.2.3', '1.2', 'v1.2.3', '1.2.3-01', '1.2.3-', '1.2.3;echo bad', 123):
            with self.subTest(version=version), self.assertRaises(ValueError):
                self.check_version(version)
