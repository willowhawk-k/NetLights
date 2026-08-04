# A formula rather than a cask on purpose: casks install .app bundles, formulae install
# command-line tools. This ships one small shim script and no application — it points at
# whichever NetLights.app you already have, which is the whole point for people who keep
# the Mac App Store build (Homebrew can't manage a Store install).
#
# Users of the `netlights` cask do NOT need this; that cask already puts `netlights` on
# PATH. The two conflict deliberately.
class NetlightsCli < Formula
  desc "Command-line shim for NetLights (works with the Mac App Store build)"
  homepage "https://github.com/willowhawk-k/NetLights"
  # Bump on every release alongside the cask. sha256 of the GitHub source tarball:
  #   curl -sL https://github.com/willowhawk-k/NetLights/archive/refs/tags/v<version>.tar.gz | shasum -a 256
  url "https://github.com/willowhawk-k/NetLights/archive/refs/tags/v1.9.0.tar.gz"
  sha256 "5e962880f8f4cbfaf8cca88dbaa9bbd014e984edcf61f470b1dfed4d0063f656"
  license "MIT"

  depends_on :macos

  conflicts_with cask:    "netlights",
                 because: "both install a `netlights` executable"

  def install
    bin.install "scripts/netlights-shim.sh" => "netlights"
  end

  def caveats
    <<~EOS
      `netlights` will run whichever NetLights.app it finds in /Applications or
      ~/Applications — including the Mac App Store build.

          netlights tui          live terminal dashboard
          netlights --dump-json  one-shot snapshot
          netlights --help       everything else

      `netlights serve` is NOT available with the App Store build: it is sandboxed
      without the incoming-connections entitlement, so it cannot listen on a socket.
      For `serve`, install the Developer-ID build instead:

          brew uninstall netlights-cli && brew install --cask netlights
    EOS
  end

  test do
    # With no NetLights.app installed the shim must fail loudly rather than silently.
    assert_match "netlights", shell_output("#{bin}/netlights --help 2>&1", 1)
  end
end
