#!/usr/bin/env bash
# Install or upgrade the Solis hub on a Raspberry Pi (Raspberry Pi OS Lite 64-bit,
# Bookworm or later). Run from a checkout, as root:
#
#   sudo deploy/pi/install.sh
#
# Safe to re-run: every step checks before it changes anything, so running it
# again is how you upgrade. See docs/hub.md.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "install.sh must run as root (try: sudo $0)" >&2
  exit 1
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_dir="$(cd "$here/../.." && pwd)"
prefix=/opt/solis-tools
state=/var/lib/solis-tools
config_dir=/etc/solis-tools
config="$config_dir/hub.json"
token_file="$state/hub-token"

for command in python3 systemctl; do
  command -v "$command" >/dev/null || { echo "$command is required" >&2; exit 1; }
done
if ! python3 -c 'import venv, ensurepip' 2>/dev/null; then
  apt-get install -y python3-venv
fi
if ! command -v avahi-daemon >/dev/null; then
  apt-get install -y avahi-daemon
fi

if ! id -u solis >/dev/null 2>&1; then
  useradd --system --home-dir "$state" --no-create-home --shell /usr/sbin/nologin solis
fi
install -d -m 0700 -o solis -g solis "$state"
install -d -m 0755 "$config_dir"

if [[ ! -x "$prefix/bin/python" ]]; then
  python3 -m venv "$prefix"
fi
"$prefix/bin/python" -m pip install --quiet "$source_dir"

fresh_config=0
if [[ ! -f "$config" ]]; then
  install -m 0640 -o root -g solis "$here/hub.json.example" "$config"
  fresh_config=1
fi

as_solis() {
  runuser -u solis -- env XDG_STATE_HOME=/var/lib "$@"
}

if [[ ! -f "$token_file" ]]; then
  token="$(as_solis "$prefix/bin/solis-hub" token new --config "$config" 2>/dev/null)"
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

install -m 0644 "$here/solis-hub.service" /etc/systemd/system/solis-hub.service
sed "s/@HUB_ID@/$hub_id/" "$here/solis-hub.avahi.service" \
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
