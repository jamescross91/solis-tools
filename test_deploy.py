"""The Pi deployment files and the hub documentation must agree with the code.

None of this needs a Pi: the files are plain text, so drift between the unit,
the Avahi advertisement, the example configuration and the hub's own constants
is caught here rather than on a fresh image.
"""

from __future__ import annotations

import configparser
import json
import re
import shutil
import subprocess
import unittest
import xml.etree.ElementTree as ElementTree
from pathlib import Path

import solis_hub

ROOT = Path(__file__).resolve().parent
PI = ROOT / "deploy" / "pi"


class DeploymentFileTests(unittest.TestCase):
    def example(self) -> dict:
        return json.loads((PI / "hub.json.example").read_text(encoding="utf-8"))

    def test_example_configuration_loads(self):
        config = solis_hub.parse_config(self.example(), Path("/tmp/solis-state"))
        self.assertEqual(config.listen_port, solis_hub.DEFAULT_PORT)

    def test_hub_documentation_shows_the_same_example(self):
        text = (ROOT / "docs" / "hub.md").read_text(encoding="utf-8")
        block = re.search(r"```json\n(\{.*?\n\})\n```", text, re.DOTALL)
        assert block is not None
        self.assertEqual(json.loads(block.group(1)), self.example())

    def test_avahi_advertises_the_hub_port_and_protocol(self):
        text = (PI / "solis-hub.avahi.service").read_text(encoding="utf-8")
        tree = ElementTree.fromstring(re.sub(r"<!DOCTYPE[^>]*>", "", text.split("?>", 1)[1]))
        service = tree.find("service")
        assert service is not None
        self.assertEqual(service.findtext("type"), "_solis-hub._tcp")
        self.assertEqual(int(service.findtext("port") or 0), self.example()["listen_port"])
        records = [item.text for item in service.findall("txt-record")]
        self.assertIn(f"proto={solis_hub.HUB_PROTOCOL_VERSION}", records)
        self.assertIn("hub_id=@HUB_ID@", records)

    def test_cloudflared_example_routes_to_the_hub_port(self):
        text = (PI / "cloudflared-config.yml.example").read_text(encoding="utf-8")
        self.assertIn(f"service: http://127.0.0.1:{self.example()['listen_port']}", text)

    def unit(self) -> configparser.ConfigParser:
        parser = configparser.ConfigParser(interpolation=None, strict=False)
        parser.optionxform = str  # type: ignore[assignment,method-assign]
        parser.read(PI / "solis-hub.service", encoding="utf-8")
        return parser

    def test_unit_waits_longer_than_the_restoration_wait(self):
        service = self.unit()["Service"]
        self.assertEqual(service["KillMode"], "mixed")
        self.assertGreater(float(service["TimeoutStopSec"]), solis_hub.RESTORATION_WAIT_S)
        self.assertEqual(service["Environment"], "XDG_STATE_HOME=/var/lib")
        self.assertIn("/var/lib/solis-tools", service["ReadWritePaths"])
        self.assertIn("serve --config /etc/solis-tools/hub.json", service["ExecStart"])

    def test_install_script_is_valid_bash_and_matches_the_unit(self):
        script = PI / "install.sh"
        bash = shutil.which("bash")
        if bash is None:
            self.skipTest("bash is not available")
        subprocess.run([bash, "-n", str(script)], check=True)
        text = script.read_text(encoding="utf-8")
        self.assertIn("state=/var/lib/solis-tools", text)
        self.assertIn("config_dir=/etc/solis-tools", text)


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
