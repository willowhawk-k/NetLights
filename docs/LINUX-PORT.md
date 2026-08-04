# NetLights → Linux port — execution plan

Ships as **2.0** across macOS (App Store + GitHub) **and** Linux, together. This is the
plan we execute through; each phase ends with a verify gate + a commit.

## Starting point (done)
- `NetLightsCore` is Foundation-only: `InterfaceModel` + `TopologySnapshot` (Codable
  contract) + `GraphLayoutEngine` (renderer-agnostic) + pure `Normalize` transforms.
- `TopologyCollector` protocol + macOS `snapshot()` + a `--dump-json` flag already exist.
- macOS is shipping **1.8.0** (App Store + Dev-ID/GitHub). The Linux work must never
  regress it.

## Goal
Full-parity Linux build, **web-rendered** (SVG/HTML over the shared engine), compatible
across the target field matrix — **Ubuntu, Debian, RHEL/Rocky, Oracle Linux, SUSE SLES**
(the enterprise families actually in the field) — and by extension their kin (Mint,
Fedora / CentOS Stream / AlmaLinux, openSUSE, Arch). Installable via
**apt / dnf-yum / zypper / AUR / AppImage** *and* native build. Windows later, same core.

## Locked decisions
1. **One fully-static binary** via Swift's **Static Linux SDK (musl)** —
   `swift build -c release --swift-sdk <arch>-swift-linux-musl`. No glibc / Swift-runtime
   / shared-lib deps → runs across **every** target distro regardless of its glibc vintage.
   This is the whole compatibility story: the enterprise LTS distros ship *old* glibc
   (RHEL 8 ≈ 2.28, SLES 15 ≈ 2.31, Debian 11 ≈ 2.31) that would otherwise force a
   lowest-common-baseline build — the musl-static binary sidesteps glibc entirely, so one
   artifact runs on all of them. Every package format wraps this same artifact.
2. **Web renderer** — `netlights` runs a small local HTTP server; the graph is SVG
   generated from the shared `GraphLayoutEngine`, the browser is the view. Reuses the
   engine, no GTK/Qt, future-proofs Windows.
3. **Full-parity collectors**, but the fiddly ones (**Bluetooth/BlueZ, Wi-Fi/nl80211**)
   **degrade-absent** — never block a release.
4. **Distribution:** self-hosted signed **APT + YUM** repos + **AUR** + **AppImage** +
   tarball, all from the static binary via **nfpm**. Defer official-distro-repo inclusion
   (months of sponsorship/burden). **Flatpak/Flathub** optional, post-2.0, for reach.
5. **Test loop:** **arm64 in UTM** on macOS (native virtualization) is primary;
   **x86_64 built + `--dump-json` smoke-tested in CI**. Operationally identical — same
   source/syscalls, both little-endian. Cover one VM per ecosystem, using the **free
   rebuilds** where the enterprise originals need a subscription — **Rocky / Oracle Linux**
   for RHEL, **openSUSE Leap** for SLES, plus **Ubuntu + Debian**.

## Distro compatibility matrix

The named field targets and how each is served. **The musl-static binary makes broad
compatibility nearly free** — it runs identically on all of them; the only genuine
per-family work is the *package wrapper* and *repo metadata*, not the code.

| Family | Pkg manager | Format | Free test stand-in |
|---|---|---|---|
| Ubuntu | apt / dpkg | `.deb` | Ubuntu (native) |
| Debian | apt / dpkg | `.deb` (oldest glibc baseline) | Debian stable |
| RHEL / Rocky | dnf-yum / rpm | `.rpm` | Rocky Linux (RHEL-identical) |
| Oracle Linux | dnf-yum / rpm | `.rpm` (same RHEL-family rpm) | Oracle Linux (free download) |
| SUSE SLES | **zypper** / rpm | `.rpm` | **openSUSE Leap** (shares the SLES codebase) |

Consequences that *shrink* the work:
- **Two package files cover all five families:** one `.deb` (Ubuntu + Debian) and one
  **zero-dependency** `.rpm` (RHEL + Rocky + Oracle **and** SLES). Because the binary is
  static and declares no runtime deps, SUSE's different dependency *names* never bite — the
  same rpm installs via `dnf`, `yum`, or `zypper`.
- **One repository serves every RPM distro:** `dnf`/`yum` and `zypper` all consume the
  standard **rpm-md** (`createrepo_c`) format, so a single signed rpm-md repo covers
  RHEL / Rocky / Oracle **and** SLES; a single APT repo covers Ubuntu + Debian.
- **Collectors are distro-agnostic.** Everything is read straight from the kernel —
  `getifaddrs`, `/proc/net/*`, `/sys/class/net`, netlink, `/sys/.../dmi`, `/etc/resolv.conf`
  — none of which depends on the distro's package manager, init, or network stack
  (NetworkManager / systemd-networkd / wicked). No per-distro collector code; the DNS reader
  already falls back from systemd-resolved to `resolv.conf` for versions without resolved.

**Where compatibility is NOT free — the native webview (Part 2).** A native GTK/WebKitGTK
window can't be fully static: it dynamically links the distro's GTK + WebKitGTK, whose
package names and sonames diverge per family (e.g. `libwebkit2gtk-4.1` on Debian/Ubuntu vs
`webkit2gtk4.1` / `webkit2gtk3` on RHEL+EPEL vs the `…-4_1-0` naming on SUSE — exact names
to confirm per release). So the **web-served / static build stays the universal compatibility
baseline**; the native-webview build is a per-family, dependency-declaring package shipped
only for the mainstream desktops, never the thing broad-distro reach depends on.

## Guardrails (checked every phase)
- **macOS parity:** `swift build` + the App Store `xcodebuild` + an Xcode Archive stay
  green; the shipping app is byte-for-byte unaffected.
- **Core purity:** no platform imports in `NetLightsCore` (the existing grep gate).
- **Cross-platform contract:** `--dump-json` schema is identical on both OSes, and a
  **captured Linux snapshot renders on macOS** — the proof the engine is platform-neutral.
- **Both arches build** (x86_64 + aarch64).

## Target shape (`Package.swift`)
```
#if os(macOS)   → executable "NetLights"       on Sources        (Core+Mac = one module, unchanged)
#else           → library    "NetLightsCore"                     (its own module)
                + executable "netlights" on Sources/NetLightsLinux
```
- Make the Core API **`public`** (needed once Linux imports it as a real module).
- Keep the macOS product named **`NetLights`** (build-app.sh depends on it).
- `Sources/NetLightsMac` is excluded from the Linux target; `Sources/NetLightsLinux`
  excluded from macOS.

---

## Phases

### L0 — Compile & run headless on Linux  *(the "does Swift + Core work here" gate)*
- `Package.swift` conditional targets; Core made `public`; `Sources/NetLightsLinux/main.swift`
  with a `LinuxCollector` **stub** returning a minimal `TopologySnapshot` (hostname +
  loopback), wired to `--dump-json`.
- **Verify Foundation provides `CGPoint`/`CGFloat` on Linux** (the known gotcha — the
  `#if canImport(CoreGraphics)` guard should fall through to Foundation's CGGeometry).
  Fix any Foundation API gaps that surface (URLSession, date/formatting, etc.).
- **Verify:** `swift build -c release` on Ubuntu (arm64/UTM) builds `netlights`;
  `--dump-json` emits schema-valid JSON; macOS still green; Core still pure.
- **Milestone:** Swift + the portable Core proven on Linux, end to end.

### L1 — Essential collectors  *(makes the graph meaningful)*
- **Interfaces/addr/MAC/MTU/flags:** `getifaddrs` + `/sys/class/net/<if>/{operstate,address,
  mtu,speed,carrier,statistics/{rx,tx}_bytes}`.
- **Routes/gateways:** `/proc/net/route` (+ `ipv6_route`); precedence from the route
  **metric** → the shared `buildGatewayNodes(rank:)`.
- **Traffic:** feed the statistics counters through the shared `TrafficRateDeriver`.
- **DNS:** systemd-resolved (D-Bus / `resolvectl` / `/run/systemd/resolve/`), fallback
  `/etc/resolv.conf`.
- **Linux category classifier:** BSD names differ (`eth*`/`enp*`/`wl*`/`wg*`/`tun*`/`br*`/
  `veth*`/`docker*`) → a Linux-specific `category(for:)` (the macOS one stays macOS).
- **Verify:** `--dump-json` cross-checks `ip addr` / `ip route` / `resolvectl`; feed the
  Linux snapshot into the **macOS** engine → it renders.
- **Milestone:** a real, data-complete snapshot on Linux.

### L2 — Web renderer  *(the UI)*
- `netlights serve`: minimal local HTTP server — `/` static HTML/JS shell,
  `/snapshot.json` the live snapshot, the graph as **SVG generated from `GraphGeometry`**
  (shared engine; `ColorToken` → CSS/SVG palette). Page polls ~0.75s, redraws; the
  Interfaces/Routes/DNS/Devices tables as HTML; Privacy toggle client-side.
- Write the **SVG emitter** over the engine geometry (bands, node rects, connection
  curves, brackets, labels) — the renderer analog of `NetworkGraphView`.
- A `.desktop` launcher + the default `netlights` invocation = serve + open browser.
- **Decision at L2:** HTTP server = SwiftNIO (robust, heavier) vs a hand-rolled minimal
  server (fewer deps, friendlier to static linking). Lean minimal unless NIO earns its keep.
- **Verify:** open in a browser on the VM; graph + tables match the machine; live traffic
  animates.
- **Milestone:** NetLights *runs* on Linux with the live graph.

### L3 — Rich collectors  *(full parity)*
- **USB tree:** `/sys/bus/usb/devices` walk (idVendor/idProduct/manufacturer/product/
  serial/bDeviceClass/speed + parent links → the `AttachedDevice` tree) reusing the shared
  `USBDeviceKind` classifiers.
- **Thunderbolt:** `/sys/bus/thunderbolt/devices`.
- **Displays + EDID:** `/sys/class/drm/*/edid` (parse maker/model/native res) — **richer
  than sandboxed macOS; a parity win.**
- **Wi-Fi SSID/link:** nl80211 over netlink (no Location gate on Linux). *Degrade-absent.*
- **Bluetooth:** BlueZ `org.bluez` via a minimal D-Bus system-bus client. *Highest risk;
  degrade-absent.*
- **Power:** `/sys/class/power_supply/*`. **machineModel:** `/sys/devices/virtual/dmi/id/
  product_name` (won't match the Mac port table → no side labels; graph still renders).
- **Verify** each vs `lsusb` / `bluetoothctl devices` / DRM sysfs / `iw`.
- **Milestone:** parity with macOS (± platform wins/gaps).

### L4 — Packaging & distribution
- **Static build:** `--swift-sdk {x86_64,aarch64}-swift-linux-musl`; confirm
  `ldd` → "not a dynamic executable". Resolve the **D-Bus-vs-static** tension (drop libdbus
  → Bluetooth absent in the static build, or speak D-Bus over its raw socket).
- **Bundle:** binary + web assets → `netlights-<version>-<arch>.tar.gz`; an **AppImage**;
  `.desktop` + icon.
- **Packages via nfpm:** one `.deb` (Ubuntu/Debian) + one zero-dep `.rpm` (RHEL / Rocky /
  Oracle **and** SLES) from a single YAML — the static binary means no per-family dep lists.
- **Repos:** self-hosted **GPG-signed APT + rpm-md** repos on GitHub Pages (the one rpm-md
  repo is consumed by `dnf`, `yum`, **and** `zypper`) + one-line `curl … | sh` repo-add
  installers per manager. **AUR** `PKGBUILD` for Arch.
- **CI (GitHub Actions):** matrix x86_64 + aarch64 → build → `--dump-json` smoke-test →
  produce every artifact → attach to the GitHub release.
- **Verify install-and-launch across the matrix:** `apt install` (Ubuntu **and** Debian),
  `dnf install` (Rocky + Oracle Linux), `zypper install` (openSUSE Leap as the SLES proxy),
  `yay -S` (Arch), and the AppImage on something exotic — each launches the graph. Optional
  Flatpak/Flathub afterward.
- **Milestone:** installable everywhere; 2.0 candidate.

### L5 — 2.0 release
- Bump to **2.0** across all channels; multi-OS launch notes; README/INSTALL per distro.
- macOS (App Store + GitHub) **and** Linux (apt/yum/AUR/AppImage) ship together.

---

## Open decisions (lock as we reach them)
- **HTTP server:** minimal hand-rolled vs SwiftNIO — decide at L2.
- **D-Bus under static musl:** drop (Bluetooth absent) vs raw-socket protocol — decide at L3/L4.
- **Flatpak:** deferred; add post-2.0 for reach.

## Risks & mitigations
- **Foundation gaps on Linux** (CGGeometry, URLSession, formatting) → surface at **L0**, shim.
- **netlink (Wi-Fi) + D-Bus (Bluetooth)** are fiddly → **degrade-absent**, never block a release.
- **static + libdbus** friction → Bluetooth optional in the static build.
- **Native-webview (Part 2) dep fragmentation** — GTK/WebKitGTK package names + sonames
  differ per family → keep the **static web-served build as the universal baseline**; ship
  native-webview only as per-family packages for mainstream desktops, never the reach-critical
  path.
- **SVG/engine drift** from the macOS graph → the "render a captured Linux snapshot on
  macOS" test keeps them identical.

## Verification harness (adds to the macOS one)
- **Linux:** `swift build -c release` (Ubuntu arm64/UTM) + `netlights --dump-json`
  schema-check + a browser smoke test.
- **Cross-platform:** `--dump-json` schema diff macOS↔Linux; render a captured Linux
  snapshot through the macOS engine.
- **Packaging:** install-and-launch on Ubuntu, Debian, Rocky, Oracle Linux, openSUSE Leap
  (SLES proxy), Arch, and the AppImage — in throwaway VMs or containers, one per ecosystem.

## Suggested milestones
- **MVP (L0–L2):** live web graph, installable as `.deb` + static tarball — ~1.5–2 weeks.
- **Full parity + broad packaging (L0–L4):** ~4–6 focused weeks (L3 netlink/D-Bus + L4 the
  variable parts).
- **2.0 (L5):** the coordinated macOS + Linux launch.
