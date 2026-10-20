import unittest
import xml.etree.ElementTree as ET
from server.build_thumbnails import svg_for


class ThumbnailTests(unittest.TestCase):
    def test_precomputed_svg_preserves_aspect_and_endpoints(self):
        root = ET.fromstring(svg_for([[118, 30], [118, 31]]))
        self.assertEqual(root.attrib['viewBox'], '0 0 180 140')
        ns = {'s': 'http://www.w3.org/2000/svg'}
        circles = root.findall('s:circle', ns)
        self.assertEqual([(c.attrib['cx'], c.attrib['cy']) for c in circles], [('90.0', '126.0'), ('90.0', '14.0')])
        self.assertEqual(svg_for([[118, 30], [118, 31]]), svg_for([[118, 30], [118, 31]]))
        self.assertNotEqual(svg_for([[118, 30], [118, 31]]), svg_for([[118, 30], [119, 30]]))

    def test_missing_route_has_no_broken_image(self):
        self.assertIsNone(svg_for([]))
        self.assertIsNone(svg_for([[118, 30]]))
