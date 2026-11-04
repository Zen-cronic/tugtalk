"""Offline manifest checks: fake Modal decorators, no account or cloud calls."""
import json
import os
import subprocess
import tempfile
from pathlib import Path
import runpy
import sys
import types
import unittest
from unittest.mock import patch

MANIFEST = Path(__file__).with_name('dashboard_app.py')


class Image:
    def __init__(self):
        self.files = []

    @classmethod
    def from_registry(cls, *args, **kwargs):
        return cls()

    def add_local_file(self, source, destination):
        self.files.append((str(source), destination))
        return self


class App:
    def __init__(self, name):
        self.name = name
        self.config = None

    def function(self, **kwargs):
        self.config = kwargs
        return lambda f: f


def fake_modal():
    return types.SimpleNamespace(App=App, Image=Image,
        Secret=types.SimpleNamespace(from_name=lambda name: name),
        concurrent=lambda **kwargs: lambda f: f,
        web_server=lambda *args, **kwargs: lambda f: f)


class DashboardManifestTests(unittest.TestCase):
    def load(self, env=None):
        with patch.dict(sys.modules, {'modal': fake_modal()}), patch.dict(os.environ, {
            'DASHBOARD_ORIGIN': 'https://dashboard.example.test',
            'DASHBOARD_UPSTREAM': 'https://connector.example.test', **(env or {})
        }):
            return runpy.run_path(str(MANIFEST))

    def test_only_explicit_assets_and_gateway_are_packaged(self):
        loaded = self.load()
        files = loaded['image'].files
        self.assertEqual(len(files), len(loaded['ASSETS']) + len(loaded['LANDING_ASSETS']) + 4)
        self.assertIn((str(MANIFEST.parents[1] / 'web' / 'dashboard-assets.json'), '/app/web/dashboard-assets.json'), files,
                      'the gateway reads the asset list at run time')
        self.assertTrue(all('/.data/' not in source and '/.env' not in source for source, _ in files))
        self.assertEqual(loaded['app'].config['include_source'], False)
        self.assertNotIn('volumes', loaded['app'].config)
        self.assertEqual(loaded['app'].name, 'comms-coach-landing')

    def test_packaged_dashboard_assets_are_the_shared_list(self):
        loaded = self.load()
        shared = json.loads((MANIFEST.parents[1] / 'web' / 'dashboard-assets.json').read_text())
        self.assertEqual(list(loaded['ASSETS']), shared)
        packaged = [dest for _, dest in loaded['image'].files if dest.startswith('/app/build/dashboard/')]
        self.assertEqual(packaged, [f'/app/build/dashboard/{name}' for name in shared])

    def test_read_only_single_instance_secure_configuration(self):
        config = self.load()['app'].config
        self.assertEqual(config['env']['DASHBOARD_ALLOW_RECORDING_CHANGES'], '0')
        self.assertEqual(config['env']['DASHBOARD_LOCAL_HTTP'], '0')
        self.assertEqual(config['max_containers'], 1)
        self.assertEqual(config['min_containers'], 0)
        self.assertEqual(config['secrets'], ['comms-coach-dashboard'])

    def test_entrypoint_loads_without_deployment_source_module(self):
        # Exercise the installed SDK's actual transport, in a child with no repository on sys.path.
        with patch.dict(os.environ, {
            'DASHBOARD_ORIGIN': 'https://dashboard.example.test',
            'DASHBOARD_UPSTREAM': 'https://connector.example.test',
        }):
            loaded = runpy.run_path(str(MANIFEST))
        info = loaded['web']._get_source_info()
        self.assertTrue(info.is_serialized())
        payload = info.serialized_function()
        child = """import sys
from modal._serialization import deserialize
from unittest.mock import patch
f = deserialize(sys.stdin.buffer.read(), None)
with patch('subprocess.Popen') as launch:
    f()
    launch.assert_called_once_with(['node', '/app/scripts/dashboard-start.mjs'], cwd='/app')
print('portable')
"""
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, '-I', '-c', child], input=payload,
                                    capture_output=True, cwd=directory)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(result.stdout.strip(), b'portable')

    def test_unsafe_or_ambiguous_origins_are_refused(self):
        for value in ['http://dashboard.example.test', 'https://user:secret@dashboard.example.test',
                      'https://dashboard.example.test/path', 'https://dashboard.example.test?key=bad']:
            with self.assertRaises(RuntimeError):
                self.load({'DASHBOARD_ORIGIN': value})


if __name__ == '__main__':
    unittest.main()
