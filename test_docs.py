"""Relative links and anchors in the documentation must resolve."""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent


class DocumentationLinkTests(unittest.TestCase):
    def test_relative_links_and_anchors_resolve(self):
        def slug(heading: str) -> str:
            return re.sub(r"[^\w\- ]", "", heading.replace("`", "").strip().lower()).replace(
                " ", "-"
            )

        pages = [*ROOT.glob("*.md"), *ROOT.glob("docs/*.md")]
        anchors = {}
        for page in pages:
            fenced = False
            found = set()
            for line in page.read_text(encoding="utf-8").splitlines():
                if line.startswith("```"):
                    fenced = not fenced
                elif not fenced and (heading := re.match(r"#+\s+(.*)", line)):
                    found.add(slug(heading.group(1)))
            anchors[page.resolve()] = found
        problems = []
        for page in pages:
            for target in re.findall(r"\]\(([^)\s]+)\)", page.read_text(encoding="utf-8")):
                if target.startswith(("http://", "https://", "mailto:")):
                    continue
                path, _, fragment = target.partition("#")
                resolved = (page.parent / path).resolve() if path else page.resolve()
                if not resolved.exists():
                    problems.append(f"{page.name}: {target}")
                elif fragment and resolved in anchors and fragment not in anchors[resolved]:
                    problems.append(f"{page.name}: {target}")
        self.assertEqual(problems, [])


if __name__ == "__main__":
    unittest.main()
