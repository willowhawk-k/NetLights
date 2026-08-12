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
Full-parity Linux build, **web-rendered** (SVG/HTML over the shared engine), for
**Ubuntu/Debian** (primary) + **Mint, Fedora/RHEL/CentOS, Arch**, installable via
**apt / dnf / AUR / AppImage** *and* native build. Windows later, same core.

## Locked decisions
1. **One fully-static binary** via Swift's **Static Linux SDK (musl)** —
   `swift build -c release --swift-sdk <arch>-swift-linux-musl`. No glibc / Swift-runtime
   / shared-lib deps → runs across all target distros. This is the portability lever;
   every package format wraps this same artifact.
2. **Web renderer** — `netlights` runs a small local HTTP server; the graph is SVG
   generated from the shared `GraphLayoutEngine`, the browser is the view. Reuses the
   engine, **no native widget toolkit UI** (no GTK/Qt views), future-proofs Windows.
   *Clarified 2026-08-10:* this rules out a hand-built widget UI, not a native
   **window**. The native window (Part 2, below) is an embedded WebKitGTK webview
   displaying this same web UI — so it does link GTK, without reintroducing a second
   renderer to keep in sync.
3. **Full-parity collectors**, but the fiddly ones (**Bluetooth/BlueZ, Wi-Fi/nl80211**)
   **degrade-absent** — never block a release.
4. **Distribution:** self-hosted signed **APT + YUM** repos + **AUR** + **AppImage** +
   tarball, all from the static binary via **nfpm**. Defer official-distro-repo inclusion
   (months of sponsorship/burden). **Flatpak/Flathub** optional, post-2.0, for reach.
5. **Test loop:** **arm64 in UTM** on macOS (native virtualization) is primary;
   **x86_64 built + `--dump-json` smoke-tested in CI**. Operationally identical — same
   source/syscalls, both little-endian.

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
- **Packages via nfpm:** `.deb` + `.rpm` (zero-dep, from the static binary) from one YAML.
- **Repos:** self-hosted **GPG-signed APT + YUM** repos on GitHub Pages + a one-line
  `curl … | sh` repo-add installer. **AUR** `PKGBUILD` for Arch.
- **CI (GitHub Actions):** matrix x86_64 + aarch64 → build → `--dump-json` smoke-test →
  produce every artifact → attach to the GitHub release.
- **Verify:** `apt install` (Ubuntu), `dnf install` (Fedora), `yay -S` (Arch), AppImage on
  something exotic — each launches the graph. Optional Flatpak/Flathub afterward.
- **Milestone:** installable everywhere; 2.0 candidate.

### Part 2 — Native desktop window (WebKitGTK)  *(after L4; sequencing decided 2026-08-10)*

A phase of its own because it is the one piece that does **not** wrap the static binary.
Approach locked 2026-07-24: an **embedded WebKitGTK webview**, Tauri-style, showing the
same web UI. (Rejected: `chromium --app` chromeless app-mode — stays static, but is not a
true embedded webview.) The same approach later gives Windows a native window via WebView2.

- **Three constraints that make it a separate track, not an L4 flag:**
  1. `webkit2gtk` is a system library, so this build links **dynamically** — it is *not*
     the fully-static binary. It is an additional **desktop variant**; the static
     `serve` binary remains the universal baseline for every distro.
  2. It **cannot cross-compile from the Mac** (the musl SDK has no webkitgtk), so it must
     be built **natively on Linux, per arch** — the one thing the current build loop
     can't do, and what the L4 CI matrix has to absorb.
  3. It has **per-distro-family dependencies** (GTK/WebKitGTK package names differ across
     Debian, RHEL and SUSE), forfeiting the zero-dep trick that lets one `.rpm` serve
     RHEL/Rocky/Oracle/SLES. This variant needs its own package set.
- **Setup on the build host/VM:** `swiftly` + a swift.org toolchain, plus
  `webkit2gtk-4.1-dev`, `libgtk-3-dev`, `build-essential`, `pkg-config`.
- **Shape:** a C system-library target (module map over webkit2gtk/`webview.h`) + a small
  Swift wrapper that starts the local server on a loopback port in the background and
  opens a native window at `http://127.0.0.1:<port>`. `#if`-guarded so the static build
  stays clean and Core stays pure.
- **Verify:** the window renders the same graph as the browser; the static build still
  cross-compiles for both arches and still has no dynamic deps.
- **Milestone:** NetLights looks like a desktop app on Linux, not a localhost URL.
- **Open:** whether 2.0 waits for this or ships on the static binary with the `.desktop`
  launcher (L2) and this lands in 2.1 — decide when L4 completes, not before.

### L5 — 2.0 release
- Bump to **2.0** across all channels; multi-OS launch notes; README/INSTALL per distro.
- macOS (App Store + GitHub) **and** Linux (apt/yum/AUR/AppImage) ship together.

---

## Open decisions (lock as we reach them)
- ~~**HTTP server:** minimal hand-rolled vs SwiftNIO~~ — **RESOLVED at L2:** hand-rolled.
  `LinuxServer.swift` is a dependency-free HTTP/1.1 server over BSD sockets.
- ~~**D-Bus under static musl:** drop (Bluetooth absent) vs raw-socket protocol~~ —
  **RESOLVED at L3:** raw socket. `NetLightsCore/DBusWire.swift` speaks the wire protocol
  directly, so the static binary keeps Bluetooth with no libdbus.
- **2.0 gating on the native window** (Part 2) vs shipping 2.0 on the static binary and
  landing the window in 2.1 — decide when L4 completes.
- ~~**GPG signing key** for the self-hosted APT/YUM repos~~ — **RESOLVED 2026-08-11:**
  a **new key created solely for NetLights**, private half held in **1Password**, and the
  **final signing step stays manual and local**. CI may build and publish unsigned
  artifacts; it never holds the private key. The reasoning is worth preserving because it
  constrains the CI design: *it is a signature, so the signer should agree with what is
  being signed* — an automated pipeline that signs whatever it just built cannot express
  agreement, only availability. Practical consequences: repo metadata is signed on the Mac
  before publication; a compromise of the CI account cannot produce a signed package; and
  the key can be rotated without touching any other identity.
- **Flatpak:** deferred; add post-2.0 for reach.

## Risks & mitigations
- **Foundation gaps on Linux** (CGGeometry, URLSession, formatting) → surface at **L0**, shim.
- **netlink (Wi-Fi) + D-Bus (Bluetooth)** are fiddly → **degrade-absent**, never block a release.
- **static + libdbus** friction → Bluetooth optional in the static build.
- **SVG/engine drift** from the macOS graph → the "render a captured Linux snapshot on
  macOS" test keeps them identical.

## Verification harness (adds to the macOS one)
- **Linux:** `swift build -c release` (Ubuntu arm64/UTM) + `netlights --dump-json`
  schema-check + a browser smoke test.
- **Cross-platform:** `--dump-json` schema diff macOS↔Linux; render a captured Linux
  snapshot through the macOS engine.
- **Packaging:** install-and-launch on Ubuntu / Fedora / Arch / AppImage in throwaway VMs
  or containers.

## Suggested milestones
- **MVP (L0–L2):** live web graph, installable as `.deb` + static tarball — ~1.5–2 weeks.
  **✅ DONE 2026-07-24.**
- **Full parity (L3):** **✅ DONE 2026-08-05/07** — collectors are functionally complete,
  Bluetooth included, and shipped inside macOS 1.9.3.
- **Broad packaging (L4):** the remaining variable part — tarball, nfpm `.deb`/`.rpm`,
  AppImage, CI matrix, then the signed repos.
- **Native window (Part 2):** after L4, per the 2026-08-10 sequencing decision.
- **2.0 (L5):** the coordinated macOS + Linux launch.
