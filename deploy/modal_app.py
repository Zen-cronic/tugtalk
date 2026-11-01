"""Synthetic-only preview; invoked using the suite's existing Poetry/Modal tool environment."""
import os
from pathlib import Path
import modal

ROOT = Path(__file__).resolve().parents[1]
app = modal.App('synthetic-coaching-connector')
volume = modal.Volume.from_name('synthetic-coaching-connector-state', create_if_missing=True, version=2)
image = (modal.Image.from_registry('node:24-bookworm-slim', add_python='3.12')
         .add_local_dir(ROOT / 'src', '/app/src')
         .add_local_file(ROOT / 'scripts' / 'handle-request.mjs', '/app/scripts/handle-request.mjs')
         .add_local_file(ROOT / 'deploy' / 'bridge.py', '/app/deploy/bridge.py'))
# Deploy with the digest of the synthetic test token, never the plaintext key or provider credentials.
bootstrap_hash = os.environ.get('CONNECTOR_TOKEN_HASH', '')
if not bootstrap_hash:
    raise RuntimeError('CONNECTOR_TOKEN_HASH is required; use deploy/prepare-and-deploy.py')

# Provider keys live only in this Modal secret (created from the ignored suite .env); never in the image or repo.
models_secret = modal.Secret.from_name('synthetic-coaching-models')

@app.function(image=image, volumes={'/data': volume}, secrets=[models_secret],
              env={'CONNECTOR_TOKEN_HASH': bootstrap_hash,
                   'CONNECTOR_PUBLIC_HOST': 'kaungzinhein113--synthetic-coaching-connector-web.us-east.modal.run'},
              min_containers=0, max_containers=1, scaledown_window=30,
              cpu=0.25, memory=512, timeout=180)
@modal.concurrent(max_inputs=1)
@modal.asgi_app()
def web():
    import sys
    sys.path.insert(0, '/app/deploy')
    from bridge import create_bridge
    return create_bridge(volume)
