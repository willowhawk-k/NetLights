# NetLights Privacy Policy

_Last updated: July 2026_

**NetLights collects no data. None. It never has.**

NetLights is a local, read-only network visualizer for macOS. Everything it shows
is read from your own Mac and displayed on your screen. The app:

- **Does not collect, store, or transmit any personal data.**
- **Has no analytics, tracking, telemetry, ads, or accounts.**
- **Makes no network connections on its own** — with two exceptions you trigger
  explicitly: the **Public IP** button, and the `serve` command-line mode (both below).
- Reads system network/hardware state **on-device only** (interfaces, routes,
  USB/Thunderbolt devices, displays, battery, Bluetooth devices) via standard macOS
  APIs, purely to draw the live graph. This information never leaves your Mac.

## External IP lookup (opt-in)

NetLights is otherwise entirely passive. The one exception is the **Public IP** button
in the toolbar. When — and only when — you click it, the app runs two small STUN lookups
(RFC 5389, UDP) against Google's public STUN servers (`stun.l.google.com`, falling back to
`stun1.l.google.com` if the first doesn't answer) to learn the public IP address the
internet currently sees for you: one over your normal route (the **exit** address —
through your VPN if one is active) and one bound to your carrier (the **underlay**
address — your real IP, bypassing the VPN). That's at most a handful of tiny UDP packets
(plus their DNS lookups). This is the app's **only** outbound network activity, it happens
**only on your click**, and never automatically.

The request carries **no personal information** — a STUN binding request is contentless;
the server simply reflects back the public IP it observes from the packet itself, which
is the same address every website you visit already sees. The result is shown on your
screen and is **not stored, logged, or sent anywhere else**. If you never press the
button, NetLights makes no outbound connections at all.

## Local web UI — `netlights serve` (GitHub build only)

The command-line `serve` mode runs a small **local** web server so you can view the same
graph in a browser — useful over SSH, or on a machine with no desktop. It is never started
by the GUI app; it exists only when you run `netlights serve` yourself.

- **It listens on `127.0.0.1` (this machine only) by default.** Nothing on your network can
  reach it. Binding a routable address is an explicit choice (`--bind all`, `--bind egress`,
  or a literal address) and prints a warning naming what is being exposed.
- **There is no authentication.** What it serves is a full inventory of your machine's
  networking — interface names, IP and MAC addresses, the route table, gateways, DNS
  servers, and attached-device names. Keep the loopback default, or use an SSH tunnel, on
  any shared network.
- It rejects requests carrying an unrecognized `Host` header, so a malicious web page in
  your browser cannot reach it via DNS rebinding.
- It makes **no outbound connections** and sends nothing anywhere — it only answers requests
  you make to it. Nothing is stored or logged.
- **The Mac App Store build cannot do this at all**: it is sandboxed without the
  "incoming network connections" entitlement, so `serve` is not included in that build.
  It is available only in the Developer-ID build from GitHub.

The `tui` command-line mode opens no sockets whatsoever — it only draws to your terminal.

## Location

macOS only reveals the current Wi-Fi network name (SSID) to apps that have Location
access. NetLights requests Location **solely** to read the SSID so it can label the
Wi-Fi uplink. **No location coordinates are ever read, stored, or shared**, and you
may decline — the uplink simply shows "Wi-Fi" instead of the network name.

## Bluetooth

macOS gates the list of connected Bluetooth devices behind Bluetooth access.
NetLights requests it **solely** to show your already-connected devices (name, type,
and input-device battery) in the graph. It **never scans for, pairs with, or connects
to** anything, and reads nothing else over Bluetooth. You may decline — the Bluetooth
entity simply doesn't appear. This is read on-device only and never leaves your Mac.

## Contact

Questions or concerns: open an issue at
<https://github.com/willowhawk-k/NetLights/issues>.
