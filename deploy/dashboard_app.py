"""Public landing and private dashboard in one application. Loading this file does not deploy it."""
import os
import json
from pathlib import Path
import subprocess
from urllib.parse import urlsplit
import modal

ROOT = Path(__file__).resolve().parents[1]
# The one dashboard asset list, also read by scripts/dashboard-build.mjs and src/dashboard-gateway.mjs.
ASSETS = tuple(json.loads((ROOT / 'web' / 'dashboard-assets.json').read_text()))


def https_origin(name):
    value = os.environ.get(name, '')
    parsed = urlsplit(value)
    if (parsed.scheme != 'https' or not parsed.hostname or parsed.username
            or parsed.password or parsed.path not in ('', '/')
            or parsed.query or parsed.fragment):
        raise RuntimeError(f'{name} must be an exact HTTPS origin without credentials or a path.')
    return value.rstrip('/')


origin = https_origin('DASHBOARD_ORIGIN')
upstream = https_origin('DASHBOARD_UPSTREAM')
# A separately provisioned secret contains only DASHBOARD_PASSWORD and
# DASHBOARD_CONNECTOR_TOKEN. No model keys or database volume are needed.
secret = modal.Secret.from_name('comms-coach-dashboard')
app = modal.App('tugtalk-landing')
image = modal.Image.from_registry('node:24-bookworm-slim', add_python='3.12')
for asset in ASSETS:
    source, built = ROOT / 'web' / asset, ROOT / 'build' / 'dashboard' / asset
    if not built.is_file() or built.read_bytes() != source.read_bytes():
        raise RuntimeError('Dashboard assets are absent or stale. Run npm run dashboard:build first.')
    # Add an explicit file allowlist, never the repository, .data or a build directory wholesale.
    image = image.add_local_file(built, f'/app/build/dashboard/{asset}')
LANDING_ASSETS = json.loads((ROOT / 'src' / 'landing-assets.json').read_text())
for asset in LANDING_ASSETS:
    if Path(asset).is_absolute() or '..' in Path(asset).parts:
        raise RuntimeError('Invalid public asset path.')
    source, built = ROOT / 'site' / asset, ROOT / 'build' / 'landing' / asset
    if not built.is_file() or built.read_bytes() != source.read_bytes():
        raise RuntimeError('Landing assets are absent or stale. Run npm run dashboard:build first.')
    image = image.add_local_file(built, f'/app/build/landing/{asset}')
image = image.add_local_file(ROOT / 'src' / 'landing-assets.json', '/app/src/landing-assets.json')
image = image.add_local_file(ROOT / 'web' / 'dashboard-assets.json', '/app/web/dashboard-assets.json')
image = (image.add_local_file(ROOT / 'src' / 'dashboard-gateway.mjs', '/app/src/dashboard-gateway.mjs')
         .add_local_file(ROOT / 'scripts' / 'dashboard-start.mjs', '/app/scripts/dashboard-start.mjs'))


@app.function(
    image=image, secrets=[secret], include_source=False, serialized=True,
    env={'DASHBOARD_ORIGIN': origin, 'DASHBOARD_UPSTREAM': upstream,
         'DASHBOARD_BIND': '0.0.0.0', 'DASHBOARD_PORT': '4321',
         'DASHBOARD_LOCAL_HTTP': '0', 'DASHBOARD_ALLOW_RECORDING_CHANGES': '0',
         # Every request arrives through the hosting proxy: sign-in throttling keys on X-Forwarded-For.
         'DASHBOARD_TRUST_PROXY': '1'},
    min_containers=0, max_containers=1, scaledown_window=300,
    cpu=0.25, memory=512, timeout=60,
)
@modal.concurrent(max_inputs=8)
@modal.web_server(4321, startup_timeout=15, label='tugtalk')
def web():
    # The proxy terminates HTTPS; the application still requires its exact public Host,
    # Secure cookies and matching Origin. It never trusts an arbitrary forwarded host.
    subprocess.Popen(['node', '/app/scripts/dashboard-start.mjs'], cwd='/app')
