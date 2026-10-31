"""Explicit deployment command. Does not upload local databases or plaintext credentials."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
key = (root / '.data' / 'operator-token.txt').read_text().strip()
if len(key) < 32:
    raise SystemExit('Missing valid synthetic token')
env = {**os.environ, 'CONNECTOR_TOKEN_HASH': hashlib.sha256(key.encode()).hexdigest(),
       'MODAL_PROFILE': 'meta-connector'}
# Invocation is deliberate: this creates/updates a cloud preview and persistent volume.
raise SystemExit(subprocess.call([sys.executable, '-m', 'modal', 'deploy', str(root / 'deploy' / 'modal_app.py'), '--env', 'main'], env=env, cwd=root))
