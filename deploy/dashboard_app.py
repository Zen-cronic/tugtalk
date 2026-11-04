"""Separate private dashboard gateway. Loading this file does not deploy it."""
import os
from pathlib import Path
import subprocess
from urllib.parse import urlsplit
import modal

ROOT = Path(__file__).resolve().parents[1]
ASSETS = (
    'index.html', 'app.js', 'practice-view.js', 'styles.css', 'icon.svg',
    'Anybody.ttf', 'HankenGrotesk.ttf', 'AzeretMono.ttf',
    'Anybody-OFL.txt', 'HankenGrotesk-OFL.txt', 'AzeretMono-OFL.txt',
)


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
app = modal.App('comms-coach-dashboard')
image = modal.Image.from_registry('node:24-bookworm-slim', add_python='3.12')
for asset in ASSETS:
    source, built = ROOT / 'web' / asset, ROOT / 'build' / 'dashboard' / asset
    if not built.is_file() or built.read_bytes() != source.read_bytes():
        raise RuntimeError('Dashboard assets are absent or stale. Run npm run dashboard:build first.')
    # Add an explicit file allowlist, never the repository, .data or a build directory wholesale.
    image = image.add_local_file(built, f'/app/build/dashboard/{asset}')
image = (image.add_local_file(ROOT / 'src' / 'dashboard-gateway.mjs', '/app/src/dashboard-gateway.mjs')
         .add_local_file(ROOT / 'scripts' / 'dashboard-start.mjs', '/app/scripts/dashboard-start.mjs'))


@app.function(
    image=image, secrets=[secret], include_source=False,
    env={'DASHBOARD_ORIGIN': origin, 'DASHBOARD_UPSTREAM': upstream,
         'DASHBOARD_BIND': '0.0.0.0', 'DASHBOARD_PORT': '4321',
         'DASHBOARD_LOCAL_HTTP': '0', 'DASHBOARD_ALLOW_RECORDING_CHANGES': '0'},
    min_containers=0, max_containers=1, scaledown_window=300,
    cpu=0.25, memory=512, timeout=60,
)
@modal.concurrent(max_inputs=8)
@modal.web_server(4321, startup_timeout=15, label='practice')
def web():
    # The proxy terminates HTTPS; the application still requires its exact public Host,
    # Secure cookies and matching Origin. It never trusts an arbitrary forwarded host.
    subprocess.Popen(['node', '/app/scripts/dashboard-start.mjs'], cwd='/app')
