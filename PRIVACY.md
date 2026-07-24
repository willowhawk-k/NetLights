# NetLights Privacy Policy

_Last updated: July 2026_

**NetLights collects no data. None. It never has.**

NetLights is a local, read-only network visualizer for macOS. Everything it shows
is read from your own Mac and displayed on your screen. The app:

- **Does not collect, store, or transmit any personal data.**
- **Has no analytics, tracking, telemetry, ads, or accounts.**
- **Makes no network connections on its own** — with one opt-in exception you trigger
  explicitly: the **Public IP** button (see below).
- Reads system network/hardware state **on-device only** (interfaces, routes,
  USB/Thunderbolt devices, displays, battery, Bluetooth devices) via standard macOS
  APIs, purely to draw the live graph. This information never leaves your Mac.

## External IP lookup (opt-in)

NetLights is otherwise entirely passive. The one exception is the **Public IP** button
in the toolbar. When — and only when — you click it, the app sends a single STUN request
(RFC 5389, UDP) to a public STUN server (Google's `stun.l.google.com`) to learn the
public IP address the internet currently sees for you: both the **exit** address (through
your VPN, if one is active) and the **underlay** address (your carrier's real IP,
bypassing the VPN). This is the app's **only** outbound network activity, it happens
**only on your click**, and never automatically.

The request carries **no personal information** — a STUN binding request is contentless;
the server simply reflects back the public IP it observes from the packet itself, which
is the same address every website you visit already sees. The result is shown on your
screen and is **not stored, logged, or sent anywhere else**. If you never press the
button, NetLights makes no outbound connections at all.

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
