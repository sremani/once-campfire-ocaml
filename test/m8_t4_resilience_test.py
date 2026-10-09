import unittest

from scripts.m8_t4_resilience import check_header_probe


class HeaderProbeTest(unittest.TestCase):
    def setUp(self):
        self.probe = {
            "front_normal": 302,
            "target_normal": 302,
            "front_large": 431,
            "target_large": None,
            "target_host_interface_reachable": False,
        }

    def test_rejects_large_headers_and_keeps_target_private(self):
        check_header_probe(self.probe)

    def test_accepted_large_header_fails(self):
        for endpoint in ("front_large", "target_large"):
            with self.subTest(endpoint=endpoint):
                probe = dict(self.probe, **{endpoint: 302})
                with self.assertRaises(AssertionError):
                    check_header_probe(probe)

    def test_public_target_fails(self):
        with self.assertRaises(AssertionError):
            check_header_probe(dict(self.probe, target_host_interface_reachable=True))

    def test_broken_normal_route_fails(self):
        with self.assertRaises(AssertionError):
            check_header_probe(dict(self.probe, target_normal=None))


if __name__ == "__main__":
    unittest.main()
