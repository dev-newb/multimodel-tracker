"""Exercise stop-before-replacement and rollback using disposable files; no live app or Keychain."""
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("installer", Path(__file__).parents[1]/"scripts/install-app.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

class InstallerTests(unittest.TestCase):
    def test_stops_before_swap(self):
        with tempfile.TemporaryDirectory() as folder:
            source, destination = Path(folder)/"source.app", Path(folder)/"installed.app"
            (source/"Contents/MacOS").mkdir(parents=True)
            (source/"Contents/MacOS/MultimodelTracker").write_text("new")
            destination.mkdir()
            (destination/"old-marker").write_text("old")
            stopped = []
            def stop(pid, signal):
                self.assertTrue((destination/"old-marker").exists())
                stopped.append(pid)
            with patch.object(sys, 'argv', ['install', '--source', str(source), '--destination', str(destination)]), \
                 patch.object(installer, 'running_pids', side_effect=[[1234], []]), \
                 patch.object(installer.os, 'kill', side_effect=stop), \
                 patch.object(installer.subprocess, 'run'):
                installer.main()
            self.assertEqual(stopped, [1234])
            self.assertEqual((destination/"Contents/MacOS/MultimodelTracker").read_text(), "new")

    def test_abort_preserves_previous_app(self):
        with tempfile.TemporaryDirectory() as folder:
            source, destination = Path(folder)/"source.app", Path(folder)/"installed.app"
            (source/"Contents/MacOS").mkdir(parents=True)
            (source/"Contents/MacOS/MultimodelTracker").write_text("new")
            destination.mkdir(); (destination/"old-marker").write_text("old")
            with patch.object(sys, 'argv', ['install', '--source', str(source), '--destination', str(destination)]), \
                 patch.object(installer, 'running_pids', return_value=[1234]), \
                 patch.object(installer.os, 'kill'), patch.object(installer.time, 'monotonic', side_effect=[0, 11]), \
                 patch.object(installer.subprocess, 'run'):
                with self.assertRaises(RuntimeError): installer.main()
            self.assertEqual((destination/"old-marker").read_text(), "old")

if __name__ == '__main__': unittest.main()
