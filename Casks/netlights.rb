cask "netlights" do
  # Bump version + sha256 together on every release. `shasum -a 256 dist/NetLights-<v>.zip`
  # after scripts/build-app.sh, or read it off the GitHub release asset.
  version "1.9.4"
  sha256 "PENDING_NOTARIZED_ZIP" # shasum -a 256 dist/NetLights-1.9.4.zip

  url "https://github.com/willowhawk-k/NetLights/releases/download/v#{version}/NetLights-#{version}.zip",
      verified: "github.com/willowhawk-k/NetLights/"
  name "NetLights"
  desc "Live, layered map of your network interfaces"
  homepage "https://github.com/willowhawk-k/NetLights"

  depends_on macos: :ventura

  app "NetLights.app"
  # Point at the shim in Contents/Resources, NOT straight at Contents/MacOS/NetLights.
  # Verified: a symlink to the executable itself does not let it resolve Bundle.main back
  # to the .app — `netlights --version` reports "dev (0)" and the LaunchServices hand-off
  # never fires. The shim execs its own bundle's binary by absolute path, so both work.
  binary "#{appdir}/NetLights.app/Contents/Resources/netlights", target: "netlights"

  # The Mac App Store build installs to the same path, /Applications/NetLights.app, so the
  # two cannot coexist. Homebrew must not delete an app it didn't install — and a Store app
  # is receipt-owned, so removing it behind the user's back would be wrong even if it were
  # possible. Detect it, explain the trade-off, and stop.
  #
  # `brew install` has to stay non-interactive (brew bundle, CI, brew upgrade), so this
  # can't be a prompt. NETLIGHTS_REPLACE_APPSTORE=1 is the explicit, scriptable "yes".
  preflight do
    mas_receipt = "/Applications/NetLights.app/Contents/_MASReceipt/receipt"
    next unless File.exist?(mas_receipt)
    next if ENV["NETLIGHTS_REPLACE_APPSTORE"]

    odie <<~EOS
      The Mac App Store build of NetLights is already installed.

      Both builds install to /Applications/NetLights.app, so only one can be present.
      Here is what changes if you switch to this (Developer-ID) build:

        GAIN  `netlights serve` — the built-in web UI. The App Store build is
              sandboxed without the incoming-connections entitlement, so it can
              never listen on a socket.
        GAIN  Updates via `brew upgrade`, and the in-app Sponsor link.
        LOSE  Automatic updates from the App Store.
        LOSE  App Sandbox confinement. This build is notarized and uses the
              hardened runtime, but it is not sandboxed.
        SAME  Everything else — the graph, `netlights tui`, all the tabs.

      To keep the App Store build and just get the CLI on your PATH:
          brew install netlights-cli
      (`tui` and `--dump-json` work there; `serve` does not.)

      To switch to this build: delete /Applications/NetLights.app (drag it to the
      Trash), then re-run:
          brew install --cask netlights

      To proceed without deleting it first — Homebrew will overwrite the app:
          NETLIGHTS_REPLACE_APPSTORE=1 brew install --cask netlights
    EOS
  end

  zap trash: [
    "~/Library/Preferences/com.willowhawk.NetLights.gh.plist",
    "~/Library/Saved Application State/com.willowhawk.NetLights.gh.savedState",
  ]

  caveats <<~EOS
    `netlights` is now on your PATH:

        netlights            open the app
        netlights tui        live terminal dashboard (top-style)
        netlights serve      serve the web UI at http://127.0.0.1:8765
        netlights --help     everything else

    `serve` listens on loopback only by default. It has no authentication and
    publishes your interfaces, addresses, routes and DNS servers, so `--bind all`
    is an explicit choice. See https://github.com/willowhawk-k/NetLights/blob/main/PRIVACY.md
  EOS
end
