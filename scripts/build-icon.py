"""Package PNG representations into ICNS without changing the supplied artwork.
Usage: python3 scripts/build-icon.py (requires macOS sips).
"""
from pathlib import Path
import struct
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = root / 'Resources/AppIcon-source.png'
representations = [('icp4', 16), ('icp5', 32), ('icp6', 64), ('ic07', 128),
                   ('ic08', 256), ('ic09', 512), ('ic10', 1024),
                   ('ic11', 32), ('ic12', 64), ('ic13', 256), ('ic14', 512)]
chunks = []
with tempfile.TemporaryDirectory(prefix='ArchiveDesk-icon-') as temp:
    for kind, size in representations:
        path = Path(temp) / (kind + '.png')
        subprocess.run(['/usr/bin/sips', '-z', str(size), str(size), str(source), '--out', str(path)], check=True, stdout=subprocess.DEVNULL)
        data = path.read_bytes()
        chunks.append(kind.encode('ascii') + struct.pack('>I', len(data) + 8) + data)
body = b''.join(chunks)
(root / 'Resources/AppIcon.icns').write_bytes(b'icns' + struct.pack('>I', len(body) + 8) + body)
