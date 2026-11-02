"""Explicit deployment command. Does not upload local databases or plaintext credentials."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
# CONNECTOR_TOKEN_FILE lets a second checkout of the repo deploy with the same token; only its digest is uploaded.
token_file = Path(os.environ.get('CONNECTOR_TOKEN_FILE') or root / '.data' / 'owner-token.txt')
key = token_file.read_text().strip()
if len(key) < 32:
    raise SystemExit('Missing valid synthetic token')
env = {**os.environ, 'CONNECTOR_TOKEN_HASH': hashlib.sha256(key.encode()).hexdigest(),
       'MODAL_PROFILE': 'meta-connector'}
# KEEP_WARM=1 keeps one container running (see deploy/modal_app.py); say which way this deploy goes.
print('KEEP_WARM is', 'on: one container stays running and is billed while it does' if os.environ.get('KEEP_WARM') == '1' else 'off', file=sys.stderr)
# Invocation is deliberate: this creates/updates a cloud preview and persistent volume.
raise SystemExit(subprocess.call([sys.executable, '-m', 'modal', 'deploy', str(root / 'deploy' / 'modal_app.py'), '--env', 'main'], env=env, cwd=root))
