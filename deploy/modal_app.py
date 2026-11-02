"""Synthetic-only preview; invoked using the suite's existing Poetry/Modal tool environment."""
import os
from pathlib import Path
import modal

ROOT = Path(__file__).resolve().parents[1]
app = modal.App('synthetic-coaching-connector')
volume = modal.Volume.from_name('synthetic-coaching-connector-state', create_if_missing=True, version=2)
image = (modal.Image.from_registry('node:24-bookworm-slim', add_python='3.12')
         .add_local_dir(ROOT / 'src', '/app/src')
         .add_local_dir(ROOT / 'eval', '/app/eval')
         .add_local_file(ROOT / 'scripts' / 'handle-request.mjs', '/app/scripts/handle-request.mjs')
         .add_local_file(ROOT / 'deploy' / 'bridge.py', '/app/deploy/bridge.py'))
# Deploy with the digest of the synthetic test token, never the plaintext key or provider credentials.
bootstrap_hash = os.environ.get('CONNECTOR_TOKEN_HASH', '')
if not bootstrap_hash:
    raise RuntimeError('CONNECTOR_TOKEN_HASH is required; use deploy/prepare-and-deploy.py')

# Provider keys live only in this Modal secret (created from the ignored suite .env); never in the image or repo.
models_secret = modal.Secret.from_name('synthetic-coaching-models')
# KEEP_WARM=1 at deploy time keeps one container running (min_containers=1), for filming windows: no cold start
# (about 3 s from Toronto, measured Nov 2). It is billed around the clock while on: at Modal's list price for 0.25 core and
# 512 MiB, about $0.016 an hour ($0.38 a day), or $0.047 an hour non-preemptible. Default off: redeploy without it after filming.
keep_warm = os.environ.get('KEEP_WARM', '') == '1'
# A container stays up for 5 minutes after its last request, so the pauses in a practice conversation do not
# cold-start the next round. Each idle tail costs at most about $0.004.
SCALEDOWN_SECONDS = 300
# REPLAY_ENABLED=1 at deploy time turns on the hands check route (src/replay.mjs); unset, the route does not exist.
replay_enabled = '1' if os.environ.get('REPLAY_ENABLED', '') == '1' else ''

@app.function(image=image, volumes={'/data': volume}, secrets=[models_secret],
              env={'CONNECTOR_TOKEN_HASH': bootstrap_hash,
                   'CONNECTOR_PUBLIC_HOST': 'kaungzinhein113--synthetic-coaching-connector-web.us-east.modal.run',
                   # The observation and the screen card ask for medium reasoning effort; the provider default stalled
                   # or came back empty on 2 of 3 bench calls. Voice replies set low in code (src/voice.mjs).
                   'ANALYSIS_EFFORT': 'medium',
                   'REPLAY_ENABLED': replay_enabled},
              min_containers=1 if keep_warm else 0, max_containers=1, scaledown_window=SCALEDOWN_SECONDS,
              cpu=0.25, memory=512, timeout=180)
# One container, several inputs at once: bridge.py runs every request on one long-lived Node worker and
# serializes database access with a lock that a model request releases during its model calls, so reads are
# served meanwhile. max_containers=1 makes this container the volume's only writer, so it never reloads it.
@modal.concurrent(max_inputs=4)
@modal.asgi_app()
def web():
    import sys
    sys.path.insert(0, '/app/deploy')
    from bridge import create_bridge
    return create_bridge(volume)
