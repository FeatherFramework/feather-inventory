"""Stage and verify the built resource, then create its install ZIP and checksum."""
import hashlib
import json
import re
import shutil
import tempfile
import zipfile
from pathlib import Path
from verify_release import runtime_files, verify

root = Path(__file__).resolve().parents[1]
version = json.loads((root / 'web/package.json').read_text(encoding='utf-8'))['version']
manifest = (root / 'fxmanifest.lua').read_text(encoding='utf-8')
match = re.search(r"^version\s+'([^']+)'", manifest, re.MULTILINE)
assert match and match.group(1) == version, 'Manifest and web package versions must match'
output = root / '.artifacts'
output.mkdir(exist_ok=True)
archive_path = output / 'feather-inventory.zip'
with tempfile.TemporaryDirectory() as temporary:
    staged = Path(temporary) / 'feather-inventory'
    staged.mkdir()
    for name in sorted(runtime_files(root)):
        destination = staged / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / name, destination)
    verify(staged)
    with zipfile.ZipFile(archive_path, 'w', zipfile.ZIP_DEFLATED) as archive:
        for file in sorted(staged.rglob('*')):
            if file.is_file():
                archive.write(file, file.relative_to(staged).as_posix())
digest = hashlib.sha256(archive_path.read_bytes()).hexdigest()
archive_path.with_suffix('.zip.sha256').write_text(f'{digest}  {archive_path.name}\n', encoding='ascii')
print(f'Created {archive_path}\nSHA-256 {digest}')
