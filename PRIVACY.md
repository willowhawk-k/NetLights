# NetLights Privacy Policy

_Last updated: June 2026_

**NetLights collects no data. None. It never has.**

NetLights is a local, read-only network visualizer for macOS. Everything it shows
is read from your own Mac and displayed on your screen. The app:

- **Does not collect, store, or transmit any personal data.**
- **Has no analytics, tracking, telemetry, ads, or accounts.**
- **Makes no network connections of its own** to send your information anywhere.
- Reads system network/hardware state **on-device only** (interfaces, routes,
  USB/Thunderbolt devices, displays, battery, Bluetooth devices) via standard macOS
  APIs, purely to draw the live graph. This information never leaves your Mac.

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
