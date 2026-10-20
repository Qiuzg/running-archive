import copy
import unittest
from server.route_preview import compact_preview

class PreviewTests(unittest.TestCase):
    def test_preserves_turns_endpoints_and_original(self):
        points = [[i / 1000, 0] for i in range(100)] + [[.1, i / 1000] for i in range(100)]
        original = copy.deepcopy(points)
        result = compact_preview(points, 16)
        self.assertLessEqual(len(result), 16)
        self.assertEqual(result[0], points[0])
        self.assertEqual(result[-1], points[-1])
        self.assertIn([.1, 0], result)
        self.assertEqual(points, original)

    def test_closed_route_does_not_collapse(self):
        points = [[0,0], [1,0], [1,1], [0,1], [0,0]]
        result = compact_preview(points, 4)
        self.assertEqual(result[0], result[-1])
        self.assertGreaterEqual(len(set(map(tuple, result))), 3)

    def test_changed_coordinates_invalidate_cached_preview(self):
        points = [[118, 32], [119, 33]]
        first = compact_preview(points, 16)
        first[0][0] = 0
        self.assertEqual(compact_preview(points, 16)[0][0], 118)
        points[-1] = [120, 34]
        self.assertEqual(compact_preview(points, 16)[-1], [120, 34])

    def test_empty_short_and_stationary_routes(self):
        self.assertEqual(compact_preview([], 16), [])
        self.assertEqual(compact_preview([[118.12345678,32.12345678]], 16), [[118.123457,32.123457]])
        self.assertEqual(compact_preview([[118,32]] * 100, 16), [[118,32], [118,32]])

if __name__ == '__main__': unittest.main()
