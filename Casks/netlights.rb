cask "netlights" do
  # Bump version + sha256 together on every release. `shasum -a 256 dist/NetLights-<v>.zip`
  # after scripts/build-app.sh, or read it off the GitHub release asset.
  version "1.9.4"
  sha256 "49da253b517d721e408ea639114c2df26da09c25273edeace7536d09ed9e6727"

  # No `verified:` — Homebrew checks the URL against the homepage host itself (both are
  # github.com/willowhawk-k/NetLights), and as of Homebrew 7 the parameter is ignored with
  # a deprecation warning on every install.
  url "https://github.com/willowhawk-k/NetLights/releases/download/v#{version}/NetLights-#{version}.zip"
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

  # The Mac App Store build installs to the same path, so the two cannot coexist. Homebrew
  # must not delete an app it didn't install — a Store app is receipt-owned, so removing it
  # behind the user's back would be wrong even if it were possible. Detect it, explain the
  # trade-off, and stop.
  #
  # This is a declarative `preflight_steps` plan, not Ruby: Homebrew 7 runs it sandboxed and
  # its audit rejects the legacy `preflight` block. The plan language has no way to test an
  # environment variable, so the old NETLIGHTS_REPLACE_APPSTORE=1 override is gone — which
  # is the more honest behaviour anyway, since overwriting a receipt-owned app is exactly
  # what this guard exists to prevent. The only path is the deliberate one: delete the App
  # Store copy, then install.
  #
  # `run` is the only step that can abort. printf shows the explanation (and exits 0), then
  # false fails the install with a one-word error line instead of echoing a script.
  preflight_steps do
    if_path_exists "NetLights.app/Contents/_MASReceipt/receipt", base: :appdir do
      run "/usr/bin/printf", args: ["%s", <<~EOS], print_stdout: true
        The Mac App Store build of NetLights is already installed.

        Both builds install to {{appdir}}/NetLights.app, so only one can be present.
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

        To switch to this build: delete {{appdir}}/NetLights.app (drag it to the
        Trash), then re-run:
            brew install --cask netlights

      EOS
      run "/usr/bin/false"
    end
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
