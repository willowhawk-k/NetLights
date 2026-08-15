# Building NetLights from source

PRs and forks welcome. NetLights is MIT-licensed, has **zero external package
dependencies**, and builds with the stock Swift toolchain.

## macOS

```bash
git clone https://github.com/willowhawk-k/NetLights.git
cd NetLights
swift run                 # build & launch
```

Requires the Xcode command-line tools (Swift 5.9+) on macOS 13 or later.

To produce a distributable app bundle and a zip for Releases:

```bash
./scripts/build-app.sh
```

Output lands in `dist/` — `dist/NetLights.app` plus `dist/NetLights-<version>.zip`.
The script reads the version from `Version.xcconfig`, the single source of truth shared
with the Xcode target, and generates the `.icns` from the in-app SwiftUI icon (no
external image tools needed).

> **`swift build` alone is not a sufficient gate.** The App Store target builds through
> Xcode with settings SwiftPM doesn't apply — most notably member-import visibility, which
> has caught real breaks that `swift build` compiled happily. Before tagging, also run:
>
> ```bash
> xcodebuild -project app/NetLights/NetLights.xcodeproj -scheme NetLights -configuration Release build
> ```

## Linux

There is no packaged release yet — build the binary yourself. See
[LINUX.md](LINUX.md) for what's implemented.

### Natively, on a Linux box

```bash
swift build -c release
./.build/release/netlights serve
```

### Fully static (musl), for a binary that runs on any distro

The portability lever is Swift's **Static Linux SDK**, which links musl and the Swift
runtime in — the result has no glibc, no Swift-runtime and no shared-library
dependencies, so one artifact runs across Ubuntu, Debian, Fedora, RHEL, SUSE and Arch:

```bash
swift build -c release --swift-sdk aarch64-swift-linux-musl
```

Use `x86_64-swift-linux-musl` for Intel/AMD. Confirm with `ldd ./.build/*/release/netlights`
— it should say *not a dynamic executable*.

### Cross-compiling from a Mac

`Package.swift` is **host-evaluated**, so `#if os(macOS)` can't distinguish a native Mac
build from a Mac-hosted cross-compile. Set `NETLIGHTS_LINUX=1` to force the Linux package:

```bash
NETLIGHTS_LINUX=1 swift build -c release --swift-sdk aarch64-swift-linux-musl
```

This needs a swift.org toolchain (via [`swiftly`](https://swift.org/install/)), not
Xcode's — the Xcode toolchain can't consume the musl SDK's Foundation. Prefix commands
with `swiftly run`, e.g. `swiftly run swift build …`.

### Packaging a release tarball

`scripts/build-linux.sh` does the whole thing — build, strip, stage, archive, verify:

```bash
./scripts/build-linux.sh
```

Both architectures by default; pass `aarch64` or `x86_64` for one. Output lands in
`dist/linux/` as `netlights-<version>-<arch>.tar.gz` plus a `.sha256`.

Stripping matters more than it sounds: unstripped Swift binaries are ~144 MB, and
`llvm-objcopy --strip-all` takes that to ~56 MB, ~22 MB compressed. (macOS's own `strip`
can't read ELF, so the script uses the `llvm-objcopy` that ships with the swiftly
toolchain.)

The tarball tree mirrors an FHS prefix so every later package format can map it
path-for-path:

```
netlights-<version>-<arch>/
├── bin/netlights
├── install.sh                                  # copies into a prefix; default /usr/local
└── share/
    ├── applications/netlights.desktop
    ├── doc/netlights/{README,LICENSE,PRIVACY,LINUX,CLI}.md
    └── icons/hicolor/{128x128,256x256,512x512}/apps/netlights.png
```

**Builds are reproducible on the same host** — the same commit built twice on the same
machine produces byte-identical tarballs. That needs all three of `SOURCE_DATE_EPOCH`
(defaults to the commit date) pinning mtimes, forced root ownership dropping the builder's
uid/gid, and `gzip -n` omitting gzip's own header timestamp; miss any one and the hash
drifts between runs.

**They are NOT reproducible across hosts**, and this was measured rather than assumed. The
same commit, same Swift 6.3.3, same Static Linux SDK, built on macOS and on the Linux CI
container, produces different binaries — `5a97b37d…` vs `cb6f81b1…` for the same aarch64
build. The difference is in the compiled binary, not the archive around it, and it is not
embedded build paths (neither binary contains one). It is somewhere in codegen or linking,
and chasing it would be a project rather than a tweak.

The practical consequence: **a CI artifact and a local artifact are not interchangeable**,
so one of them has to be the canonical source of published Linux binaries. Do not treat a
hash mismatch between the two as evidence that something is wrong.

The script refuses to package a binary that isn't ELF, isn't statically linked, or doesn't
match the requested architecture, then re-extracts the finished tarball and re-checks it —
the artifact is verified, not the staging directory it came from.

### Building the .deb and .rpm

`scripts/build-packages.sh` turns the tarballs into packages via [nfpm](https://nfpm.goreleaser.com/):

```bash
./scripts/build-packages.sh
```

It builds from the **extracted release tarball**, not from a fresh staging pass, so the
bytes users install are provably the bytes they can download and hash.

`packaging/nfpm.yaml.in` is a template rather than a config: nfpm's own environment
expansion does not reach `contents.src`, so the script substitutes the version, arch and
stage path and writes a rendered `nfpm.yaml` beside the extracted tree — which also makes
"what exactly went into this package" answerable by reading one file.

**Zero dependencies is load-bearing.** The binary is fully static, so `depends` is empty —
and that is what lets a single `.rpm` serve RHEL, Rocky, Oracle Linux *and* SLES, which
otherwise disagree on package names for the same libraries. Adding one real dependency
collapses that into per-family builds.

### Building the AppImage

```bash
./scripts/build-appimage.sh
```

There is no `appimagetool` for macOS — it is itself a Linux AppImage — and it is not
needed. A type-2 AppImage is just the AppImage runtime (a small static ELF that mounts the
rest of itself) with a SquashFS image concatenated on the end, so `mksquashfs` plus `cat`
covers it, and the AppImage builds on the Mac like every other artifact.

The runtime is fetched once into `dist/linux/.runtime/` and checked against
`packaging/appimage-runtime.sha256` on **every** build — cached copies included, since a
file already on disk is not automatically trustworthy. Upstream publishes it under a
rolling `continuous` tag, so if they republish, the build stops rather than quietly
adopting a different runtime; verify deliberately, then update the pin.

`AppRun` with no arguments runs `serve --open`, because bare `netlights` defaults to
`serve` *without* opening a browser and that makes a double-clicked AppImage look like it
did nothing. Explicit arguments pass straight through, so `./NetLights-*.AppImage tui`
works.

Verification reads the SquashFS back out **at the runtime's offset** and checks that
`AppRun`, the desktop entry, `.DirIcon` and the binary are all present. An ELF header at
the front only proves the runtime is there; this proves the concatenation produced
something mountable, which is the part that can silently go wrong.

### Verifying a Linux build

Copy the binary to the Linux machine and run the verification suite **there**:

```bash
chmod +x verify-linux-cli.sh && ./verify-linux-cli.sh ./netlights
```

It checks static linkage, the CLI grammar, JSON schema validity, bind behaviour and the
`--bind all` warning. Don't run it on macOS — one section binds `0.0.0.0`, which trips
the macOS Application Firewall prompt and hangs the script.

## Continuous integration

Two workflows in `.github/workflows/`, all on standard GitHub-hosted runners (free and
unlimited on public repositories):

**`ci.yml`** — every push and pull request:
- macOS: `swift build` plus the **App Store `xcodebuild` Release build**. That second one is
  not redundant: the Xcode target applies settings SwiftPM does not, and its absence once
  produced a tagged release that could not be archived at all. The Xcode version is
  *asserted* rather than selected, so an image bump fails loudly instead of silently
  changing what the gate means.
- Linux: both architectures cross-compiled in the official `swift:6.3.3` container, then
  **executed** on `ubuntu-latest` and `ubuntu-24.04-arm` — `--dump-json` with a schema
  assertion, plus the full `verify-linux-cli.sh` suite. This is the only place the x86_64
  binary runs at all.

**`release.yml`** — on tag: builds all four Linux formats, attests build provenance, and
uploads to a **draft** release. Draft rather than published so nothing reaches the releases
page unreviewed. See [RELEASING.md](RELEASING.md).

Neither workflow signs anything. Verify an artifact came from a given workflow run with:

```bash
gh attestation verify <file> --repo willowhawk-k/NetLights
```

## Source tree

```
Sources/
├── NetLightsCore/            # portable, Foundation-only — no platform imports
│   ├── InterfaceModel.swift      # data models, TopologySnapshot, per-Mac port layout table
│   ├── Normalize.swift           # pure transforms: gateways, egress, route classification
│   ├── GraphLayoutEngine.swift   # renderer-agnostic geometry (bands, tidy tree, wires)
│   ├── GraphSVGRenderer.swift    # the graph as SVG (used by `serve`)
│   ├── TUIRender.swift           # the terminal dashboard, as a pure snapshot -> ANSI function
│   ├── TrafficRates.swift        # shared rate deriver, so app/TUI/web report the same numbers
│   ├── DNSParsing.swift          # pure parsers for resolv.conf / resolvectl status
│   └── CommandLine.swift         # the CLI grammar, identical on every platform
├── NetLightsHost/            # libc layer: termios terminal driver + BSD-socket web server
├── NetLightsMac/             # the macOS app
│   ├── NetLightsCLI.swift        # @main: dispatches GUI vs tui/serve/--dump-json
│   ├── NetLightsApp.swift        # SwiftUI App, menu commands, dock icon, lifecycle
│   ├── ContentView.swift         # Tabs: Graph / Routes / Interfaces / Devices / DNS
│   ├── NetworkMonitor.swift      # system data gathering (sysctl/IOKit/CoreWLAN/SC)
│   ├── IOKitProbe.swift          # IOKit/CoreGraphics probes (USB tree, TB, displays, power)
│   ├── BluetoothProbe.swift      # IOBluetooth connected-device list (TCC-gated, optional)
│   ├── NetworkGraphView.swift    # the layered graph in SwiftUI
│   └── *NodeView / *EntityView / Tooltips / AboutView / HelpView / AssetExport
└── NetLightsLinux/           # the Linux collectors + entry point
scripts/build-app.sh          # packages dist/NetLights.app + zip
scripts/build-linux.sh        # static Linux binaries -> release tarballs, both arches
scripts/build-packages.sh     # those tarballs -> .deb + .rpm, via nfpm
scripts/build-appimage.sh     # those tarballs -> AppImages (runtime + squashfs)
scripts/verify-linux-cli.sh   # CLI verification suite, run on a Linux box
packaging/nfpm.yaml.in        # package description template (rendered by build-packages.sh)
packaging/scripts/            # postinstall/postremove: desktop + icon cache refresh
packaging/appimage-runtime.sha256  # pinned hashes for the upstream AppImage runtime
```

The invariant that keeps the port honest: **`NetLightsCore` imports nothing but
Foundation.** Anything touching libc goes in `NetLightsHost`; anything touching a
platform framework goes in `NetLightsMac` or `NetLightsLinux`.

On macOS, Core + Mac compile as **one** executable module — the real module boundary only
materializes for the Linux build, where `NetLightsCore` is a separate library and
`NetLightsMac` isn't built at all.

## Adding your Mac's port layout

If your model shows generic port positions, extend `hardwarePortLayout(model:)` in
`Sources/NetLightsCore/InterfaceModel.swift` with your `hw.model` identifier:

```bash
sysctl hw.model
```

**Help ▸ Send Feedback** in the app opens a prefilled issue already tagged with your app
version, macOS version and Mac model — the easiest way to contribute a layout or file a
bug. A screenshot of the graph helps too.

## Developer & diagnostic flags

Each exits without showing a window:

| Flag | What it does |
|------|--------------|
| `--probe-dump` | Prints the in-process IOKit / CoreGraphics probe results (Thunderbolt receptacles, USB-C power, system power, iPhone, BSD→receptacle map, and the USB/display attached-device list with classified kinds) to stdout, so they can be diffed against `ioreg` / `system_profiler` ground truth. (Bluetooth devices aren't included in the dump.) |
| `--export-iconset <dir>` | Renders the SwiftUI app icon to a `.iconset` directory (all sizes) for packaging. Used by `scripts/build-app.sh`. |

```bash
swift run NetLights --probe-dump                            # from source
dist/NetLights.app/Contents/MacOS/NetLights --probe-dump    # the packaged binary
```

## Related docs

- [CLI.md](CLI.md) — the full command-line reference
- [LINUX.md](LINUX.md) — Linux collector status and known differences
- [LINUX-PORT.md](LINUX-PORT.md) — the port's phased execution plan
- [../APPSTORE.md](../APPSTORE.md) — the sandboxed App Store target
- [AI-ASSIST.md](AI-ASSIST.md) — how this codebase was pair-programmed with Claude
