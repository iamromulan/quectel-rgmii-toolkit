#!/usr/bin/env python3
"""Tests for the version logic in plan_build.py:  python3 -I -m unittest discover .github/scripts"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import plan_build as pb  # noqa: E402


class Versions(unittest.TestCase):
    def sign(self, a, b):
        c = pb.compare_versions(a, b)
        return (c > 0) - (c < 0)

    def test_compare(self):
        cases = [("1.0", "1.0", 0), ("1.0-r1", "1.0", 1), ("1.0", "1.0-r1", -1),
                 ("1.0-r2", "1.0-r10", -1), ("1.104.4", "1.104.2", 1),
                 ("2024.07.22~b610860d-r3", "2024.07.22~b610860d-r3", 0),
                 ("1.0~rc1", "1.0", -1), ("1:0.1", "2.0", 1), ("0.9-1", "0.9-2", -1)]
        for a, b, want in cases:
            self.assertEqual(self.sign(a, b), want, (a, b))

    def test_bump(self):
        self.assertEqual(pb.bump_version("1.0"), "1.0-r1")
        self.assertEqual(pb.bump_version("1.0-r1"), "1.0-r2")
        self.assertEqual(pb.bump_version("0.9-1"), "0.9-2")
        self.assertEqual(pb.bump_version("2.3.2-r20250207"), "2.3.2-r20250208")

    def test_bump_is_greater(self):
        for v in ("1.0", "1.0-r1", "0.9-1", "1.104.2", "1.3.4-20250119", "3.2"):
            self.assertGreater(pb.compare_versions(pb.bump_version(v), v), 0, v)


if __name__ == "__main__":
    unittest.main()
