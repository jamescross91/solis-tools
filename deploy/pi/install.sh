#!/usr/bin/env bash
# Install or upgrade the Solis hub on a Raspberry Pi (Raspberry Pi OS Lite 64-bit,
# Bookworm or later). Run from a checkout, as root:
#
#   sudo deploy/pi/install.sh [--python PATH] [--check-python]
#
# Safe to re-run: every step checks before it changes anything, so running it
# again is how you upgrade. See docs/hub.md.
#
# The hub needs Python 3.10 or newer (pymodbus 3.10 does not install on older
# versions). The interpreter is chosen and checked first, before anything on the
# system changes, so an unsuitable Pi fails at once and leaves nothing behind.
set -euo pipefail

# Everything up to the root check uses only shell builtins and the candidate
# interpreters, so the check also works with almost nothing else on PATH, which is
# how the tests drive it.
here="${BASH_SOURCE[0]%/*}"
here="$(cd "$here" && pwd)"
MIN_PYTHON="3.10"
requested_python="${SOLIS_PYTHON:-}"
check_only=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --python)
      [[ $# -ge 2 ]] || { echo "--python needs a path" >&2; exit 2; }
      requested_python="$2"
      shift 2
      ;;
    --check-python)
      check_only=1
      shift
      ;;
    -h | --help)
      echo "usage: sudo $0 [--python PATH] [--check-python]"
      echo "  --python PATH    build the virtualenv with this Python (3.10 or newer)"
      echo "  --check-python   report which Python would be used and change nothing"
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 2
      ;;
  esac
done

python_ok() {
  "$1" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null
}

python_version() {
  "$1" -c 'import platform; print(platform.python_version())' 2>/dev/null || echo unknown
}

# An explicit choice is never second-guessed or silently replaced. Otherwise the
# system python3 wins, so apt's python3-venv matches it, then newer versions, then
# the interpreter docs/hub.md has you build on an older image.
python=""
if [[ -n "$requested_python" ]]; then
  if ! command -v "$requested_python" >/dev/null 2>&1; then
    echo "ERROR: $requested_python does not exist or is not executable." >&2
    exit 1
  fi
  if ! python_ok "$requested_python"; then
    echo "ERROR: $requested_python is Python $(python_version "$requested_python"); the hub needs $MIN_PYTHON or newer." >&2
    exit 1
  fi
  python="$requested_python"
else
  for candidate in python3 python3.13 python3.12 python3.11 python3.10 /opt/python-3.11/bin/python3.11; do
    if command -v "$candidate" >/dev/null 2>&1 && python_ok "$candidate"; then
      python="$candidate"
      break
    fi
  done
fi
if [[ -z "$python" ]]; then
  found="none"
  if command -v python3 >/dev/null 2>&1; then
    found="python3 is $(python_version python3)"
  fi
  {
    echo "ERROR: the hub needs Python $MIN_PYTHON or newer, and none was found ($found)."
    echo
    echo "Raspberry Pi OS Bullseye ships Python 3.9, which cannot install pymodbus 3.10."
    echo "Either:"
    echo "  - flash Raspberry Pi OS Lite 64-bit, Bookworm or later (Python 3.11), or"
    echo "  - build Python 3.11 on this Pi (docs/hub.md, \"Older images, such as Bullseye\""
    echo "    has the commands), then run this script again."
    echo
    echo "Nothing has been changed on this system."
  } >&2
  exit 1
fi
python="$(command -v "$python")"
if [[ $check_only -eq 1 ]]; then
  echo "$python (Python $(python_version "$python"))"
  exit 0
fi

if [[ $EUID -ne 0 ]]; then
  echo "install.sh must run as root (try: sudo $0)" >&2
  exit 1
fi

source_dir="$(cd "$here/../.." && pwd)"
prefix=/opt/solis-tools
state=/var/lib/solis-tools
config_dir=/etc/solis-tools
config="$config_dir/hub.json"
token_file="$state/hub-token"

command -v systemctl >/dev/null || { echo "systemctl is required" >&2; exit 1; }
if ! "$python" -c 'import venv, ensurepip' 2>/dev/null; then
  # Only the distribution's own interpreter can be completed by apt; anything else
  # was built or installed by hand and has to bring venv with it.
  if [[ "$python" == /usr/bin/* ]]; then
    apt-get install -y python3-venv
  fi
  "$python" -c 'import venv, ensurepip' ||
    { echo "ERROR: $python cannot create virtualenvs (venv or ensurepip is missing)." >&2; exit 1; }
fi
if ! command -v avahi-daemon >/dev/null; then
  apt-get install -y avahi-daemon
fi

if ! id -u solis >/dev/null 2>&1; then
  useradd --system --home-dir "$state" --no-create-home --shell /usr/sbin/nologin solis
fi
install -d -m 0700 -o solis -g solis "$state"
install -d -m 0755 "$config_dir"

# A virtualenv left by an earlier run on an older Python can never install the hub,
# and running the installer again would fail the same way. It holds nothing but the
# installed package, so replace it rather than reuse it.
if [[ -f "$prefix/pyvenv.cfg" ]] && ! { [[ -x "$prefix/bin/python" ]] && python_ok "$prefix/bin/python"; }; then
  echo "Replacing the virtualenv at $prefix: it was built with Python $(python_version "$prefix/bin/python"), and the hub needs $MIN_PYTHON or newer."
  rm -rf "$prefix"
fi
if [[ ! -x "$prefix/bin/python" ]]; then
  "$python" -m venv "$prefix"
fi
# pip's own output stays visible: its reason for a failure is the only clue to a
# network or index problem.
if ! "$prefix/bin/python" -m pip install --disable-pip-version-check --no-cache-dir "$source_dir"; then
  echo "ERROR: pip could not install the hub with Python $(python_version "$prefix/bin/python") from $source_dir." >&2
  echo "Check that this Pi can reach https://pypi.org, then run this script again." >&2
  exit 1
fi
# pip builds in the checkout as root; leave nothing there that blocks a later
# git pull or make as a normal user.
rm -rf "$source_dir/build" "$source_dir"/*.egg-info

fresh_config=0
if [[ ! -f "$config" ]]; then
  install -m 0640 -o root -g solis "$here/hub.json.example" "$config"
  fresh_config=1
fi

as_solis() {
  runuser -u solis -- env XDG_STATE_HOME=/var/lib "$@"
}

if [[ ! -f "$token_file" ]]; then
  token="$(as_solis "$prefix/bin/solis-hub" token new --config "$config")"
  echo
  echo "Hub token (shown once, enter it in the menu-bar app): $token"
  echo
fi
as_solis "$prefix/bin/solis-hub" check --config "$config" >/dev/null

if [[ ! -s "$state/hub-id" ]]; then
  cat /proc/sys/kernel/random/uuid >"$state/hub-id"
  chown solis:solis "$state/hub-id"
  chmod 0600 "$state/hub-id"
fi
hub_id="$(tr -d '[:space:]' <"$state/hub-id")"
# Read the port back from the retained configuration, so an upgrade does not
# advertise 8765 for a hub that was moved to another port.
listen_port="$("$prefix/bin/python" -c \
  'import json, sys; print(json.load(open(sys.argv[1])).get("listen_port", 8765))' "$config")"

install -m 0644 "$here/solis-hub.service" /etc/systemd/system/solis-hub.service
sed -e "s/@HUB_ID@/$hub_id/" -e "s/@PORT@/$listen_port/" "$here/solis-hub.avahi.service" \
  >/etc/avahi/services/solis-hub.service
chmod 0644 /etc/avahi/services/solis-hub.service

systemctl daemon-reload
systemctl enable solis-hub.service >/dev/null
systemctl enable --now avahi-daemon.service >/dev/null

if [[ $fresh_config -eq 1 ]]; then
  echo "Edit $config and set the data logger's address in poller_args,"
  echo "then run: sudo systemctl start solis-hub"
else
  systemctl restart solis-hub.service
  echo "solis-hub restarted. Check it with: systemctl status solis-hub"
fi
