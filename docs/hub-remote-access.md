# Reaching the hub from outside the home

Away from home, clients connect to a stable HTTPS address that reaches the hub
without opening a router port, and without anything installed on the phone or
the Mac. The installer sets this up with Tailscale Funnel by default. A
Cloudflare Tunnel is the alternative for anyone who already has a domain on
Cloudflare.

Either way the hub refuses requests without its bearer token. Remember that the
token can also change control settings, so keep it as you would a password.

## Tailscale Funnel (the default)

`sudo deploy/pi/install.sh` finishes by running `deploy/pi/remote-access.sh`,
which:

1. installs Tailscale from Tailscale's signed apt repository, if it is not
   already installed, and enables `tailscaled`;
2. runs `tailscale up` if the Pi is not signed in, which prints a link: open
   it, sign in with a free personal account and approve the device;
3. runs `tailscale funnel --bg <port>`, which the first time prints a second
   link to approve Funnel (and HTTPS certificates) for the tailnet, and keeps
   Funnel on across reboots;
4. prints the address, such as `https://raspberrypi.tail1234.ts.net`.

Then:

- In the Tailscale admin console's Machines page, choose **Disable key expiry**
  for the Pi. Otherwise the Pi's key expires after some months and remote access
  stops while you are away.
- Enter the address as the Remote URL in the menu bar's Hub settings, leave the
  Cloudflare fields empty, and use Test connection. Public DNS can take up to
  ten minutes to list a new address.

Funnel is public: anyone can reach the address, and only the hub token stands
in front of the hub. Requests arrive from `tailscaled` on loopback with the
visitor's address in `X-Forwarded-For`, which Tailscale's proxy sets itself, so
the hub's failed-authentication limit applies per visitor. Tailscale applies
its own bandwidth limits to Funnel traffic; the hub's stream, a few kilobytes
per sample while someone is watching, is far below them. Funnel is still
labelled beta by Tailscale.

To stop publishing the hub: `sudo tailscale funnel --https=443 off`.

## Cloudflare Tunnel (the alternative)

Install with `--no-remote` (or turn Funnel off as above), then follow these
steps. `cloudflared` on the Pi makes an outbound connection to Cloudflare.
Cloudflare's free tier covers everything here: a tunnel, a public hostname, an
Access application and a service token, but it needs a domain whose DNS is on
Cloudflare.

The hub needs no Cloudflare-specific code beyond reading the visitor's address
from `X-Forwarded-For` (or `CF-Connecting-IP`) for rate limiting when the
request arrives from loopback. Two layers protect it, and either failing open is
not enough:

1. Cloudflare Access refuses requests without a valid service token.
2. The hub refuses requests without its own bearer token.

Dashboard menu names change from time to time; look for the Access controls,
Applications and Service credentials sections if a name below has moved.

### 1. Create the tunnel

You need a domain whose DNS is on Cloudflare. In the Cloudflare dashboard open
Zero Trust, then Networks, then Tunnels, and create a tunnel of type
Cloudflared. Name it (for example `solis-hub`). The dashboard shows the
command to install `cloudflared` on the Pi and connect it with a token; run
that command on the Pi. The tunnel should show as healthy.

Prefer a locally managed tunnel? Run `cloudflared tunnel login`, then
`cloudflared tunnel create solis-hub` and `cloudflared tunnel route dns solis-hub
energy.example.com`. Copy `deploy/pi/cloudflared-config.yml.example`
to `/etc/cloudflared/config.yml`, fill in the tunnel UUID and hostname, and run
`sudo cloudflared service install`. Both routes lead to the same place: the hostname
must route to `http://127.0.0.1:8765`.

### 2. Add the public hostname

In the tunnel's settings add a public hostname: subdomain `energy`, your
domain, service type HTTP, URL `127.0.0.1:8765`. WebSocket upgrades work by
default. Do not turn on any option that buffers responses, and do not put a
caching rule on the hostname.

Check from outside the home: before step 3, `curl
https://energy.example.com/v1/healthz` prints `{"ok":true}`. After step 3 the
same request is refused by Cloudflare unless it carries the service token
headers, which is the point.

### 3. Create a service token

In Access, then Service Auth, create a service token. Cloudflare shows the
Client ID and Client Secret once. Copy both into the menu-bar app's hub
settings (Cloudflare Access client ID and secret). They are stored in the
Keychain and sent on every request as `CF-Access-Client-Id` and
`CF-Access-Client-Secret`. Service
tokens expire after a period you choose, so note the expiry and rotate it
before then.

Also enter the remote URL (`https://energy.example.com`) and the hub's bearer
token (`solis-hub token show`).

### 4. Put Cloudflare Access in front

Still in Zero Trust, open Access, then Applications, and add a self-hosted
application for `energy.example.com`. Create a policy with the action
"Service Auth" that includes the service token you just created. Do not add any
policy that allows by email or "Everyone": nobody should reach the hostname
without a token.

## How the clients choose

Clients try the LAN endpoint first (the Bonjour result or the manual LAN URL)
with a 2 second connect timeout, then the remote URL. They re-evaluate when the
network path changes, so leaving the house moves the connection to the tunnel
without any action. The "Test connection" button in the menu-bar app shows
which endpoint answered. Remote connections are always `wss://`.

## Things to check when it does not work

| Symptom | Check |
| --- | --- |
| Cloudflare error page or a login redirect | The service token is missing from the Access policy, or the client is not sending the two headers |
| 401 with no Cloudflare page | Cloudflare let it through but the hub's bearer token is wrong |
| 429 from the hub | Ten failed attempts in a minute from that client address (as reported by `CF-Connecting-IP`) |
| Connects, then drops every minute or so | Something in front of the tunnel is buffering or timing out the WebSocket; check for proxies and caching rules on the hostname |
