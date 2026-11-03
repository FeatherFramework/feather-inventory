"""Validate resource/package versions and, when supplied, a release tag."""
import argparse
import json
from pathlib import Path
import re


def verify(root, tag=None):
    version = json.loads((root / 'web/package.json').read_text(encoding='utf-8-sig'))['version']
    identifier = r'(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
    semver = rf'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-{identifier}(?:\.{identifier})*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?'
    if not isinstance(version, str) or not re.fullmatch(semver, version):
        raise ValueError('web/package.json must contain a valid semantic version')
    manifest = (root / 'fxmanifest.lua').read_text(encoding='utf-8-sig')
    versions = re.findall(r'''^\s*version\s+['"]([^'"]+)['"]\s*(?:--[^\n]*)?$''', manifest, re.MULTILINE)
    if versions != [version]:
        raise ValueError('fxmanifest.lua and web/package.json versions must match exactly')
    if tag is not None and tag not in (version, 'v' + version):
        raise ValueError('Release tag must equal the package version, optionally prefixed with v')
    return version


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag')
    args = parser.parse_args()
    try:
        print('PASS version ' + verify(Path(__file__).resolve().parents[1], args.tag))
    except (ValueError, KeyError) as error:
        raise SystemExit(str(error)) from error
