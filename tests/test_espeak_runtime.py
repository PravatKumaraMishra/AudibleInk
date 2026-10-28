"""Keep eSpeak data paths short when the app lives in a deep directory."""
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
from worker import configure_espeak_data


class EspeakRuntimeTests(unittest.TestCase):
    def test_long_data_path_is_copied_to_worker_temporary_directory(self):
        with tempfile.TemporaryDirectory(dir='/tmp') as directory:
            root = Path(directory)
            source = root / ('nested-' * 25) / 'espeak-ng-data'
            source.mkdir(parents=True)
            (source / 'phontab').write_bytes(b'phoneme data')
            temporary = root / 'worker'
            temporary.mkdir()
            wrapper = Mock()
            with patch.dict(sys.modules, {
                'espeakng_loader': types.SimpleNamespace(get_data_path=lambda: str(source)),
                'misaki.espeak': types.SimpleNamespace(EspeakWrapper=wrapper),
            }):
                configure_espeak_data(temporary)
                configure_espeak_data(temporary)
            target = temporary / 'espeak-ng-data'
            self.assertEqual((target / 'phontab').read_bytes(), b'phoneme data')
            wrapper.set_data_path.assert_called_with(str(target))
            self.assertLess(len(str(target)), 150)
