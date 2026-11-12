#!/usr/bin/env python3

from __future__ import annotations

import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools" / "stress"))

import run_category  # noqa: E402


class StressCategoryParsingTests(unittest.TestCase):
    def test_preserves_existing_categories_and_adds_modern_protocol(self) -> None:
        self.assertTrue(
            {"concurrency", "largeoutput", "hang", "badargs", "protocol"}
            .issubset(run_category.CATEGORIES)
        )
        self.assertIn("modern", run_category.CATEGORIES)

    def test_every_declared_category_has_a_runner(self) -> None:
        for category in run_category.CATEGORIES:
            with self.subTest(category=category):
                self.assertEqual(
                    run_category.parse_category(["run_category.py", category]),
                    category,
                )
                self.assertTrue(callable(run_category.category_runner(category)))

    def test_invalid_category_reports_usage(self) -> None:
        with self.assertRaisesRegex(ValueError, "usage:"):
            run_category.parse_category(["run_category.py"])
        with self.assertRaisesRegex(ValueError, "usage:"):
            run_category.parse_category(["run_category.py", "nope"])
        with self.assertRaisesRegex(ValueError, "unknown stress category"):
            run_category.category_runner("nope")


if __name__ == "__main__":
    unittest.main()
