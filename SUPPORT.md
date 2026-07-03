# NetLights — Support

Need help with NetLights, hit a bug, or want to request a feature? Here's how to get support.

## Ask a question or report a problem

Open an issue on the GitHub tracker — this is the fastest way to reach the developer:

**https://github.com/willowhawk-k/NetLights/issues**

- **Bug reports:** please include your macOS version, your Mac model (run `sysctl hw.model`
  in Terminal), the NetLights version (shown in **NetLights ▸ About**), and a screenshot
  if the issue is visual. If a specific device or port shows up wrong, mentioning it helps.
- **Questions / feature requests:** open an issue and describe what you're trying to do.
- **A different Mac layout:** if your model shows generic port positions, an issue with your
  `hw.model` lets us add it to the built-in layout table.

## Common questions

- **Why does it ask for Location / Bluetooth?** Location is used *only* to read the current
  Wi-Fi network name (SSID); Bluetooth is used *only* to list your already-connected devices.
  Both are optional — decline and the app simply omits that label/entity. Nothing is collected,
  stored, or transmitted. See [PRIVACY.md](PRIVACY.md).
- **Is my data collected?** No. NetLights is read-only, makes no network connections of its
  own, and has no analytics or accounts. See [PRIVACY.md](PRIVACY.md).
- **Where do I see what a device/interface is?** Hover any node, or open the **Interfaces**,
  **Routes**, and **Devices** tabs for full tables.

NetLights is free and open source (MIT). Full documentation is in the
[README](README.md).
