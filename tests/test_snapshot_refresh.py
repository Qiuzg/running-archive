import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from server.snapshot_refresh import request_refresh, refresh

class RefreshTests(unittest.TestCase):
    def test_new_requests_during_build_survive(self):
        with tempfile.TemporaryDirectory() as d:
            queue = Path(d) / 'queue'
            request_refresh(queue)
            old = set(queue.iterdir())
            with patch('server.snapshot_refresh.time.sleep'), patch('server.snapshot_refresh.build', return_value={}), patch('server.snapshot_refresh.publish'), patch('server.snapshot_refresh.build_thumbnails', side_effect=lambda *args: request_refresh(queue)):
                refresh(queue, Path(d))
            self.assertEqual(len(list(queue.iterdir())), 1)
            self.assertFalse(set(queue.iterdir()) & old)

    def test_failure_keeps_retry_request(self):
        with tempfile.TemporaryDirectory() as d:
            queue = Path(d) / 'queue'
            request_refresh(queue)
            with patch('server.snapshot_refresh.time.sleep'), patch('server.snapshot_refresh.build', side_effect=RuntimeError('failed')):
                with self.assertRaises(RuntimeError): refresh(queue, Path(d))
            self.assertEqual(len(list(queue.iterdir())), 1)
