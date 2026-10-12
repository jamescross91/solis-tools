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
import sys
import tempfile
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
        # The port is rendered from hub.json by install.sh, so an upgrade keeps a
        # custom listen_port advertised.
        self.assertEqual(service.findtext("port"), "@PORT@")
        installer = (PI / "install.sh").read_text(encoding="utf-8")
        self.assertIn("listen_port", installer)
        self.assertIn("s/@PORT@/$listen_port/", installer)
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


class InstallerPythonTests(unittest.TestCase):
    """The interpreter check runs before the installer changes anything.

    A Pi on Bullseye has Python 3.9, where pymodbus 3.10 cannot install. The
    installer used to find that out half way through, after creating the user and
    a virtualenv. `--check-python` exposes the choice without touching the system,
    so it can be driven here with stand-in interpreters.
    """

    OLD = '#!/bin/sh\ncase "$*" in *sys.exit*) exit 1;; *) echo 3.9.2;; esac\n'
    NEW = '#!/bin/sh\ncase "$*" in *platform*) echo 3.11.9;; *) exit 0;; esac\n'

    def run_installer(self, interpreters: dict[str, str], *args: str, env=None):
        bash = shutil.which("bash")
        if bash is None:
            self.skipTest("bash is not available")
        with tempfile.TemporaryDirectory() as directory:
            for name, body in interpreters.items():
                path = Path(directory) / name
                path.write_text(body, encoding="utf-8")
                path.chmod(0o755)
            # Only the stand-ins are on PATH, so a real python3.11 on the machine
            # running the tests cannot be picked up by accident.
            result = subprocess.run(
                [bash, str(PI / "install.sh"), "--check-python", *args],
                env={"PATH": directory, **(env or {})},
                capture_output=True,
                text=True,
                check=False,
            )
            return result, directory

    def test_python_39_is_refused_before_anything_changes(self):
        result, _ = self.run_installer({"python3": self.OLD})
        self.assertEqual(result.returncode, 1)
        self.assertIn("3.10 or newer", result.stderr)
        self.assertIn("python3 is 3.9.2", result.stderr)
        self.assertIn("Nothing has been changed", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_no_python_at_all_is_refused(self):
        result, _ = self.run_installer({})
        self.assertEqual(result.returncode, 1)
        self.assertIn("none was found (none)", result.stderr)

    def test_a_newer_interpreter_beside_an_old_python3_is_used(self):
        result, directory = self.run_installer({"python3": self.OLD, "python3.11": self.NEW})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), f"{directory}/python3.11 (Python 3.11.9)")

    def test_a_suitable_system_python3_wins(self):
        result, directory = self.run_installer({"python3": self.NEW, "python3.12": self.NEW})
        self.assertEqual(result.stdout.strip(), f"{directory}/python3 (Python 3.11.9)")

    def test_an_explicit_interpreter_is_never_replaced(self):
        result, directory = self.run_installer(
            {"python3": self.NEW, "old": self.OLD}, "--python", "old"
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("old is Python 3.9.2", result.stderr)
        result, directory = self.run_installer(
            {"python3": self.OLD, "new": self.NEW}, env={"SOLIS_PYTHON": "new"}
        )
        self.assertEqual(result.stdout.strip(), f"{directory}/new (Python 3.11.9)")

    def test_a_missing_explicit_interpreter_is_reported(self):
        result, _ = self.run_installer({"python3": self.NEW}, "--python", "nowhere")
        self.assertEqual(result.returncode, 1)
        self.assertIn("nowhere does not exist", result.stderr)

    def test_unsuitable_virtualenv_is_replaced_not_reused(self):
        text = (PI / "install.sh").read_text(encoding="utf-8")
        self.assertIn('rm -rf "$prefix"', text)
        self.assertIn("pyvenv.cfg", text)
        self.assertNotIn("--quiet", text)


RUNNING = {
    "BackendState": "Running",
    "Self": {"DNSName": "raspberrypi.tail1234.ts.net.", "KeyExpiry": "2027-04-01T00:00:00Z"},
}


def published(port: int, funnel: bool = True) -> dict:
    host = "raspberrypi.tail1234.ts.net:443"
    return {
        "TCP": {"443": {"HTTPS": True}},
        "Web": {host: {"Handlers": {"/": {"Proxy": f"http://127.0.0.1:{port}"}}}},
        "AllowFunnel": {host: True} if funnel else {},
    }


class RemoteAccessTests(unittest.TestCase):
    """remote-access.sh, run against stand-ins for tailscale, apt and systemd.

    Every command it uses is a stand-in on PATH that records how it was called,
    so nothing on the machine running the tests is touched.
    """

    def run_script(
        self, status: dict | None, serve: dict | None = None, *, installed=True, distro="debian"
    ):
        bash = shutil.which("bash")
        if bash is None:
            self.skipTest("bash is not available")
        directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, directory)
        self.last_directory = directory
        log = directory / "calls.log"
        (directory / "status.json").write_text(json.dumps(status or {"BackendState": "NeedsLogin"}))
        (directory / "serve.json").write_text(json.dumps(serve or {}))
        (directory / "running.json").write_text(json.dumps(RUNNING))
        (directory / "os-release").write_text(f"ID={distro}\nVERSION_CODENAME=bookworm\n")
        record = f'echo "${{0##*/}} $*" >> "{log}"\n'
        stand_ins = {
            "id": "#!/bin/sh\necho 0\n",
            "systemctl": "#!/bin/sh\n" + record,
            "apt-get": "#!/bin/sh\n" + record,
            "curl": "#!/bin/sh\n" + record,
            "install": "#!/bin/sh\n" + record,
        }
        cat, cp, chmod = (shutil.which(tool) for tool in ("cat", "cp", "chmod"))
        tailscale = (
            "#!/bin/sh\n"
            + record
            + 'case "$*" in\n'
            + f'  "status --json") {cat} "{directory}/status.json" ;;\n'
            + f'  "serve status --json") {cat} "{directory}/serve.json" ;;\n'
            # Signing in is what moves the stand-in from NeedsLogin to Running.
            + f'  up*) {cp} "{directory}/running.json" "{directory}/status.json" ;;\n'
            + "esac\n"
        )
        if installed:
            stand_ins["tailscale"] = tailscale
        else:
            # apt-get install puts tailscale on PATH, as the real one would.
            stand_ins["apt-get"] = (
                "#!/bin/sh\n"
                + record
                + f'case "$*" in *"install -y tailscale"*) printf %s \'{tailscale}\' > "{directory}/tailscale"; '
                + f'{chmod} 755 "{directory}/tailscale" ;; esac\n'
            )
        for name, body in stand_ins.items():
            path = directory / name
            path.write_text(body, encoding="utf-8")
            path.chmod(0o755)
        result = subprocess.run(
            [bash, str(PI / "remote-access.sh"), "8765"],
            env={
                "PATH": str(directory),
                "SOLIS_OS_RELEASE": str(directory / "os-release"),
                "SOLIS_JSON_PYTHON": sys.executable,
                "SOLIS_STATE_DIR": str(directory),
            },
            capture_output=True,
            text=True,
            check=False,
        )
        calls = log.read_text().splitlines() if log.exists() else []
        return result, calls

    def test_a_fresh_pi_is_signed_in_and_published(self):
        result, calls = self.run_script({"BackendState": "NeedsLogin"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("tailscale up", calls)
        self.assertIn("tailscale funnel --bg 8765", calls)
        self.assertIn("systemctl enable --now tailscaled.service", calls)
        self.assertIn("Remote address: https://raspberrypi.tail1234.ts.net", result.stdout)
        self.assertIn("Disable key expiry", result.stdout)
        self.assertEqual(
            (Path(self.last_directory) / "public-url").read_text(),
            "https://raspberrypi.tail1234.ts.net\n",
        )
        self.assertEqual(
            solis_hub.parse_public_url((Path(self.last_directory) / "public-url").read_text()),
            "https://raspberrypi.tail1234.ts.net",
        )

    def test_running_again_changes_nothing(self):
        result, calls = self.run_script(RUNNING, published(8765))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("tailscale up", calls)
        self.assertFalse(any(call.startswith("tailscale funnel") for call in calls))
        self.assertFalse(any(call.startswith(("apt-get", "curl")) for call in calls))
        self.assertIn("Remote address: https://raspberrypi.tail1234.ts.net", result.stdout)

    def test_a_published_but_private_hub_is_made_public(self):
        _, calls = self.run_script(RUNNING, published(8765, funnel=False))
        self.assertIn("tailscale funnel --bg 8765", calls)

    def test_someone_elses_service_on_443_is_left_alone(self):
        result, calls = self.run_script(RUNNING, published(3000))
        self.assertEqual(result.returncode, 1)
        self.assertIn("already publishes something else", result.stderr)
        self.assertFalse(any(call.startswith("tailscale funnel") for call in calls))

    def test_tailscale_comes_from_its_signed_apt_repository(self):
        result, calls = self.run_script({"BackendState": "NeedsLogin"}, installed=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg "
            "-o /usr/share/keyrings/tailscale-archive-keyring.gpg",
            calls,
        )
        self.assertIn("apt-get install -y tailscale", calls)
        self.assertIn("tailscale funnel --bg 8765", calls)
        # Never a downloaded script piped into a shell.
        self.assertNotIn("install.sh", " ".join(calls))

    def test_a_system_without_a_package_source_stops_with_instructions(self):
        result, calls = self.run_script(
            {"BackendState": "NeedsLogin"}, installed=False, distro="fedora"
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("tailscale.com/download/linux", result.stderr)
        self.assertFalse(any(call.startswith("apt-get") for call in calls))

    def test_no_key_expiry_warning_once_it_is_disabled(self):
        status = {**RUNNING, "Self": {"DNSName": "raspberrypi.tail1234.ts.net."}}
        result, _ = self.run_script(status, published(8765))
        self.assertNotIn("key expiry", result.stdout)

    def test_the_installer_runs_it_last_and_survives_its_failure(self):
        text = (PI / "install.sh").read_text(encoding="utf-8")
        self.assertIn("--no-remote", text)
        self.assertLess(
            text.index("systemctl restart solis-hub.service"), text.index('remote-access.sh" ')
        )
        self.assertIn('if ! SOLIS_JSON_PYTHON="$prefix/bin/python" "$here/remote-access.sh"', text)
        bash = shutil.which("bash")
        if bash is not None:
            subprocess.run([bash, "-n", str(PI / "remote-access.sh")], check=True)


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
