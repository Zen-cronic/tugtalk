"""Offline manifest checks: fake Modal decorators, no account or cloud calls."""
import os
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
        self.assertEqual(len(files), len(loaded['ASSETS']) + 2)
        self.assertTrue(all('/.data/' not in source and '/.env' not in source for source, _ in files))
        self.assertEqual(loaded['app'].config['include_source'], False)
        self.assertNotIn('volumes', loaded['app'].config)

    def test_read_only_single_instance_secure_configuration(self):
        config = self.load()['app'].config
        self.assertEqual(config['env']['DASHBOARD_ALLOW_RECORDING_CHANGES'], '0')
        self.assertEqual(config['env']['DASHBOARD_LOCAL_HTTP'], '0')
        self.assertEqual(config['max_containers'], 1)
        self.assertEqual(config['min_containers'], 0)
        self.assertEqual(config['secrets'], ['comms-coach-dashboard'])

    def test_unsafe_or_ambiguous_origins_are_refused(self):
        for value in ['http://dashboard.example.test', 'https://user:secret@dashboard.example.test',
                      'https://dashboard.example.test/path', 'https://dashboard.example.test?key=bad']:
            with self.assertRaises(RuntimeError):
                self.load({'DASHBOARD_ORIGIN': value})


if __name__ == '__main__':
    unittest.main()
