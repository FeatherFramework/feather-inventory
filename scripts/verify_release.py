"""Verify Inventory's runtime-only directory or install ZIP."""
import argparse
import re
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

ROOT_FILES = {'fxmanifest.lua', 'config.lua', 'LICENSE', 'README.md'}
RUNTIME_DIRS = {'client', 'server', 'translations', 'database', 'ui'}


def allowed(name):
    path = PurePosixPath(name)
    if name in ROOT_FILES:
        return True
    if len(path.parts) < 2:
        return False
    if path.parts[0] in {'client', 'server', 'translations'}:
        return path.suffix == '.lua'
    if path.parts[0] == 'database':
        return path.suffix == '.sql'
    if name == 'ui/index.html':
        return True
    if path.parts[:2] == ('ui', 'assets') and len(path.parts) == 3:
        return path.suffix in {'.js', '.css', '.png', '.jpg', '.jpeg', '.svg', '.webp', '.woff', '.woff2', '.ttf', '.ico'}
    if path.parts[:3] == ('ui', 'images', 'items') and len(path.parts) == 4:
        return path.suffix.lower() in {'.png', '.jpg', '.jpeg', '.webp', '.svg'}
    return name == 'ui/favicon.ico'


def runtime_files(root):
    required = set(ROOT_FILES)
    for folder in sorted(RUNTIME_DIRS):
        assert (root / folder).is_dir(), f'Missing runtime directory: {folder}'
        for file in (root / folder).rglob('*'):
            assert not file.is_symlink(), f'Symlink in runtime: {file}'
            if file.is_file():
                name = file.relative_to(root).as_posix()
                assert allowed(name), f'Non-runtime file: {name}'
                required.add(name)
    return required


def verify(root):
    required = runtime_files(root)
    actual = set()
    for file in root.rglob('*'):
        name = file.relative_to(root).as_posix()
        assert not file.is_symlink(), f'Symlink in archive: {name}'
        if file.is_file():
            actual.add(name)
        else:
            assert name.split('/')[0] in RUNTIME_DIRS, f'Non-runtime directory: {name}'
    assert actual == required, f'Runtime file mismatch: extra={actual-required}, missing={required-actual}'
    for name in ROOT_FILES:
        assert (root / name).is_file(), f'Missing {name}'
    manifest = (root / 'fxmanifest.lua').read_text(encoding='utf-8')
    assert re.search(r"ui_page\s*(?:\{\s*)?'ui/index\.html'", manifest), 'Manifest must load ui/index.html'
    # Check every quoted local script/file pattern against the staged archive.
    for block in re.findall(r'(?:shared_scripts|client_scripts|server_scripts|files)\s*\{([^}]+)\}', manifest):
        for pattern in re.findall(r"'([^']+)'", block):
            if pattern.startswith('@'):
                continue
            assert list(root.glob(pattern.lstrip('/'))), f'Missing manifest files: {pattern}'
    entry = (root / 'ui/index.html').read_text(encoding='utf-8')
    assets = re.findall(r'(?:src|href)="([^"?#]+)"', entry)
    assert any(asset.endswith('.js') for asset in assets), 'Missing compiled JS entry'
    for asset in assets:
        assert asset.startswith('./') and '..' not in PurePosixPath(asset).parts, f'Non-relative entry asset: {asset}'
        assert (root / 'ui' / asset).is_file(), f'Missing entry asset: {asset}'
    assert (root / 'ui/images/items').is_dir(), 'Missing item images'
    for css in (root / 'ui/assets').glob('*.css'):
        for asset in re.findall(r'url\(\s*[\'"]?([^\)\'"\s]+)', css.read_text(encoding='utf-8')):
            if asset.startswith('data:'):
                continue
            assert not asset.startswith(('http:', 'https:', '/')), f'Non-relative CSS asset: {asset}'
            resolved = (css.parent / asset.split('?')[0].split('#')[0]).resolve()
            assert resolved.is_relative_to((root / 'ui').resolve()) and resolved.is_file(), f'Missing CSS asset: {asset}'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('artifact', type=Path)
    args = parser.parse_args()
    if args.artifact.is_dir():
        verify(args.artifact)
    else:
        with tempfile.TemporaryDirectory() as temporary, zipfile.ZipFile(args.artifact) as archive:
            names = set()
            for entry in archive.infolist():
                path = PurePosixPath(entry.filename)
                assert path.parts and not path.is_absolute() and '..' not in path.parts and '\\' not in entry.filename, 'Unsafe ZIP path'
                assert entry.filename not in names, 'Duplicate ZIP entry'
                names.add(entry.filename)
                assert allowed(entry.filename), f'Unexpected ZIP entry: {entry.filename}'
                assert (entry.external_attr >> 16) & 0o170000 != 0o120000, 'ZIP symlink'
            archive.extractall(temporary)
            verify(Path(temporary))
    print('PASS runtime layout, manifest paths, compiled entry, fonts and item images')


if __name__ == '__main__':
    main()
