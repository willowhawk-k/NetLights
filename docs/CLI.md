# Command-line reference

Running NetLights with no arguments opens the app as usual (on macOS). It is also a
small command-line tool — the **same grammar on macOS and Linux** — for terminals and
servers.

| Command | What it does | Availability |
|---------|--------------|--------------|
| `netlights` | Opens the graphical app (the default). | macOS |
| `netlights tui` | A live, full-screen terminal dashboard, `top`-style. | everywhere |
| `netlights serve` | Runs the built-in web server and prints its URL — the same graph in a browser, plus `/snapshot.json`. | GitHub build + Linux |
| `netlights --dump-json` | Prints one `TopologySnapshot` as JSON and exits. | everywhere |

```bash
netlights tui                      # live dashboard in your terminal
netlights tui --once --view routes # one frame, no terminal needed (pipes, cron, CI)
netlights serve --port 9000        # browse at http://127.0.0.1:9000
netlights --dump-json | jq .interfaces
ssh box 'netlights tui'            # works fine over SSH
```

## Options

| Option | Applies to | What it does |
|--------|-----------|--------------|
| `-h`, `--help` | | Show help and exit. |
| `-V`, `--version` | | Show version information and exit. |
| `--dump-json` | | Print one snapshot as JSON to stdout and exit. |
| `--compact` | `--dump-json` | Emit compact rather than pretty JSON. |
| `--interval SEC` | `tui`, `serve` | Refresh interval, 0.1–3600 (default 1.0). |
| `--view NAME` | `tui` | Start on `graph`, `routes`, `interfaces`, `devices` or `dns`. |
| `--once` | `tui` | Print one frame and exit — works without a terminal (pipes, cron, CI). |
| `--no-color` | `tui` | Disable colour. `NO_COLOR` is honoured too. |
| `--port N` | `serve` | TCP port to listen on (default 8765). |
| `--bind ADDR` | `serve` | Address to listen on (default `loopback`) — see below. |
| `--open` | `serve` | Open the URL in the default browser. |

Unknown arguments are rejected with a suggestion for near misses (`--serve` → `serve`),
rather than silently ignored.

## `tui` — the terminal dashboard

| Key | Action |
|-----|--------|
| `g` / `1` | Graph |
| `r` / `2` | Routes |
| `i` / `3` | Interfaces |
| `d` / `4` | Devices |
| `n` / `5` | DNS |
| `h` | Hide/show inactive interfaces |
| `p` | Privacy mode (mask IP/MAC addresses) |
| `s` | Toggle route sort |
| `SPACE` | Pause / resume |
| `q`, `Ctrl-C` | Quit |

The **Graph** view stacks the same OSI bands the app draws, starting with **Hardware
(L0)**: each receptacle, the interfaces it carries, and the device tree hanging off it —
so a USB-Ethernet adapter and the interface it provides appear together, and a hub owns
its children.

It resizes with the window, restores your terminal on exit (including after `Ctrl-Z` /
`fg`), and opens no sockets — so it works in the sandboxed App Store build and over SSH.
Link state uses distinct glyphs, not just colour, so `--no-color` and `--once` into a file
stay readable.

`--once` prints a single frame to stdout and exits, which needs no terminal at all:
pipe it, cron it, drop it in CI.

## `serve` — the web UI

`serve` starts a small HTTP server and prints its URL. `/` is the same graph the app
draws, rendered as SVG from the shared layout engine, with tabs for Routes, Interfaces,
Devices and DNS.

| Path | What it returns |
|------|-----------------|
| `/` | the page |
| `/graph.svg` | the graph, laid out for the browser's viewport |
| `/ui.json` | the tables, with every cell already formatted by the app's own helpers |
| `/snapshot.json` | the raw live `TopologySnapshot` — the `--dump-json` contract |

### Privacy and Hide inactive

The browser has the same two controls as the TUI, in the top right — or press **p** and
**h**. Both are reflected in the URL (`?privacy=1&hide=1`), so a masked view can be
bookmarked or handed to someone else and stays masked.

Both are resolved **server-side**. For *Hide inactive* that's forced — the graph is
server-rendered SVG, so only the layout engine can drop nodes. For *Privacy* it's the
stronger choice anyway: `serve` has no authentication, so masking before the response is
written means the real addresses never cross the wire, rather than relying on the page not
to render them. `/snapshot.json` honours the flags too.

The graph re-lays-out when you resize the window, the same way the app's graph follows the
window.

### `--bind` values

| Value | Listens on | Who can reach it |
|-------|-----------|------------------|
| `loopback` *(default)* | `127.0.0.1` | this machine only |
| `all` | `0.0.0.0` | every interface — **LAN-visible** |
| `egress` | the primary uplink's own address | that network |
| an IPv4 literal | that address | whatever can route to it |

> **`serve` listens on `127.0.0.1` only, by default.** It has **no authentication** and
> publishes your interfaces, addresses, routes, DNS servers and gateway addresses, so
> exposing it to the network (`--bind all`) is an explicit choice that prints a warning.
> Prefer an SSH tunnel on any shared network. See [../PRIVACY.md](../PRIVACY.md).

The **Mac App Store** build cannot listen at all — the sandbox has no
incoming-connections entitlement — so `serve` ships only in the Developer-ID / Homebrew
build. `tui` and `--dump-json` work in both.

## `--dump-json`

Prints one `TopologySnapshot` — the same Codable contract the app, the TUI and the web UI
all consume — and exits. The schema is **identical on macOS and Linux**, which is what
lets a snapshot captured on one render on the other.

```bash
netlights --dump-json --compact > snapshot.json
```

The current `schemaVersion` is **3**. Changes are additive, so a reader written against an
earlier version still works:

| Version | Change |
|---------|--------|
| 3 | added `serviceRank` (interface → macOS network-service order, the macOS analog of a Linux route metric). Empty on Linux. |
| 2 | `RouteEntry.id` is no longer encoded — it was a random UUID, so two dumps of an unchanged machine differed by hundreds of lines. |
| 1 | initial cross-platform contract. |

## Installing the command

The easiest route is Homebrew — one tap, then either package:

```bash
brew tap willowhawk-k/tap
brew install --cask netlights     # the app + the `netlights` command
```

If you already have NetLights from the **Mac App Store** and only want the command line,
install the shim instead (the App Store build can't `serve`, but `tui` and `--dump-json`
work):

```bash
brew install netlights-cli
```

Install one or the other — both provide a `netlights` executable. Without Homebrew, point
your `PATH` at the shim inside the bundle:

```bash
sudo ln -sf "/Applications/NetLights.app/Contents/Resources/netlights" /usr/local/bin/netlights
```

Link the shim in `Contents/Resources`, **not** the executable in `Contents/MacOS` — a
symlink straight to the executable stops it resolving its own bundle, so it reports the
wrong version and won't open the app window.

## A note on macOS privacy prompts

A process started from a terminal is attributed to **the terminal**, not to NetLights, and
macOS treats a privacy-gated call in that state as fatal rather than denied. So the CLI
modes deliberately skip the Bluetooth and display-name probes. Interfaces, routes, DNS,
USB and Thunderbolt all work normally — see [MACOS.md](MACOS.md#command-line-behaviour-on-macos).

Typing `netlights` with no arguments hands off to LaunchServices, so the window opens as a
properly-attributed app with the full device list.
