import json
import sqlite3
import tempfile
import unittest
from pathlib import Path
from server.build_atlas import project, publish, build


class AtlasSnapshotTests(unittest.TestCase):
    def test_projection_keeps_vertical_and_horizontal_shape(self):
        self.assertEqual(project([[118, 30], [118, 31]]), '130.0,120.0 130.0,10.0')
        self.assertEqual(project([[118, 30], [119, 30]]), '10.0,65.0 250.0,65.0')

    def test_failed_write_preserves_previous_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'atlas.json'
            publish({'entries': []}, path)
            with self.assertRaises(ValueError):
                publish({'bad': float('nan')}, path)
            self.assertEqual(json.loads(path.read_text()), {'entries': []})
            self.assertEqual(list(Path(directory).iterdir()), [path])

    def test_database_selection_and_precomputed_points(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'test.db'
            with sqlite3.connect(path) as db:
                db.executescript('''
                    CREATE TABLE routes (id TEXT, name TEXT, distance_km REAL, coordinates TEXT, preview_coordinates TEXT);
                    CREATE TABLE races (id TEXT, source_run_id TEXT, route_id TEXT, name TEXT, date TEXT, distance_km REAL, type TEXT);
                    CREATE TABLE run_records (id TEXT, route_id TEXT, name TEXT, date TEXT, distance_km REAL);
                    INSERT INTO routes VALUES ('race-route', 'Race', 21.1, '[[118,30],[119,31]]', '[]');
                    INSERT INTO routes VALUES ('short-route', 'Short', 5, '[[118,30],[119,31]]', '[]');
                    INSERT INTO races VALUES ('race', 'duplicate', 'race-route', 'Race', '2026-01-02', 21.1, 'half_marathon');
                    INSERT INTO run_records VALUES ('duplicate', 'race-route', 'Duplicate', '2026-01-02', 21.1);
                    INSERT INTO run_records VALUES ('short', 'short-route', 'Short', '2026-01-01', 5);
                ''')
            snapshot = build(path)
        ids = [item['id'] for item in snapshot['entries']]
        self.assertEqual(ids, ['race-route'])
        self.assertEqual(snapshot['entries'][0]['kind'], 'half')
        self.assertEqual(len(ids), len(set(ids)))
        self.assertTrue(all(item['distance_km'] > 10 and item['points'] for item in snapshot['entries']))
        self.assertEqual([r['date'] for r in snapshot['entries']], sorted([r['date'] for r in snapshot['entries']], reverse=True))
