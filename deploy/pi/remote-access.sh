#!/usr/bin/env bash
# Publish the hub at a fixed public HTTPS address with Tailscale Funnel, so the
# menu bar and the iPhone reach it away from home with nothing installed on
# them. install.sh runs this by default; it is safe to run again on its own:
#
#   sudo deploy/pi/remote-access.sh [PORT]
#
# The first run asks for two things in a browser, both printed as links: signing
# the Pi in to Tailscale, and approving Funnel for the tailnet. See docs/hub.md.
set -euo pipefail

port="${1:-8765}"
# The variables below exist so the tests can stand in for the system; nothing
# else should need them.
os_release="${SOLIS_OS_RELEASE:-/etc/os-release}"
state="${SOLIS_STATE_DIR:-/var/lib/solis-tools}"
python="${SOLIS_JSON_PYTHON:-/opt/solis-tools/bin/python}"
[[ -x "$python" ]] || python="$(command -v python3)"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "remote-access.sh must run as root (try: sudo $0)" >&2
  exit 1
fi

if ! command -v tailscale >/dev/null 2>&1; then
  # shellcheck disable=SC1090
  . "$os_release"
  case "${ID:-}" in
    debian | raspbian | ubuntu) ;;
    *)
      echo "ERROR: no Tailscale package source for ${ID:-this system}." >&2
      echo "Install Tailscale (https://tailscale.com/download/linux), then run this again." >&2
      exit 1
      ;;
  esac
  codename="${VERSION_CODENAME:?/etc/os-release names no VERSION_CODENAME}"
  command -v curl >/dev/null 2>&1 || apt-get install -y curl
  # Tailscale's own signed repository rather than its piped install script, so
  # what is trusted is a key, and later upgrades arrive with the system's own.
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL "https://pkgs.tailscale.com/stable/$ID/$codename.noarmor.gpg" \
    -o /usr/share/keyrings/tailscale-archive-keyring.gpg
  curl -fsSL "https://pkgs.tailscale.com/stable/$ID/$codename.tailscale-keyring.list" \
    -o /etc/apt/sources.list.d/tailscale.list
  apt-get update
  apt-get install -y tailscale
fi
systemctl enable --now tailscaled.service >/dev/null

status_field() {
  tailscale status --json 2>/dev/null | "$python" -c '
import json, sys
try:
    value = json.load(sys.stdin)
except ValueError:
    value = {}
for key in sys.argv[1].split("."):
    value = value.get(key) if isinstance(value, dict) else None
print(value or "")
' "$1"
}

if [[ "$(status_field BackendState)" != "Running" ]]; then
  echo
  echo "Sign this Pi in to Tailscale: open the link below, sign in and approve the device."
  echo "(A free personal account is enough. The phone and the Mac do not need Tailscale.)"
  tailscale up
fi

# Funnel on 443 forwards to the hub. Another service already published there is
# someone's own setup: leave it alone rather than replace it.
serve_state="$(tailscale serve status --json 2>/dev/null || echo '{}')"
published="$("$python" -c '
import json, sys
try:
    config = json.loads(sys.argv[1] or "{}")
except ValueError:
    config = {}
port = sys.argv[2]
state = "free"
for host, web in (config.get("Web") or {}).items():
    if not host.endswith(":443"):
        continue
    proxy = ((web.get("Handlers") or {}).get("/") or {}).get("Proxy", "")
    ours = proxy.rstrip("/").endswith((f"127.0.0.1:{port}", f"localhost:{port}"))
    public = (config.get("AllowFunnel") or {}).get(host, False)
    state = "done" if ours and public else ("ours" if ours else "other")
print(state)
' "$serve_state" "$port")"
case "$published" in
  done) ;;
  other)
    echo "WARNING: Tailscale already publishes something else on port 443 of this Pi." >&2
    echo "Remote access was not changed. See \"Reaching the hub from outside the home\" in docs/hub.md." >&2
    exit 1
    ;;
  *)
    echo
    echo "Publishing the hub with Tailscale Funnel. If a link appears, open it and approve"
    echo "Funnel for your tailnet; this continues once you have."
    tailscale funnel --bg "$port"
    ;;
esac

name="$(status_field Self.DNSName)"
name="${name%.}"
echo
if [[ -n "$name" ]]; then
  # The hub tells connected apps this address, so they use it away from home
  # without anyone typing it. Readable by the hub's own user; not a secret.
  if [[ -d "$state" ]]; then
    (umask 022 && printf 'https://%s\n' "$name" >"$state/public-url")
  fi
  echo "Remote address: https://$name"
  echo "Apps that have connected to the hub at home pick this up by themselves. On a"
  echo "new device, enter it as the hub address with the token. It can take up to ten"
  echo "minutes to appear in public DNS the first time."
else
  echo "Funnel is on; run 'tailscale funnel status' to see the address."
fi
if [[ -n "$(status_field Self.KeyExpiry)" ]]; then
  echo
  echo "Turn off key expiry for this Pi, or remote access stops when its key expires:"
  echo "  https://login.tailscale.com/admin/machines  (menu next to this Pi, Disable key expiry)"
fi
