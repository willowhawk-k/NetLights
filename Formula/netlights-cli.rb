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
  url "https://github.com/willowhawk-k/NetLights/archive/refs/tags/v1.9.3.tar.gz"
  sha256 "6b22cfef735fb3c027d38f4293dedc27e60648e9eba0041d752feb483932d89a"
  license "MIT"

  depends_on :macos

  # NOTE: Homebrew's Formula DSL has no formula-vs-CASK conflict. `conflicts_with cask:`
  # is silently accepted and does nothing, so it was removed rather than left as a false
  # guarantee — the caveats below carry the warning instead.

  def install
    bin.install "scripts/netlights-shim.sh" => "netlights"
  end

  def caveats
    <<~EOS
      Do NOT install this alongside the `netlights` cask — both provide a `netlights`
      command and Homebrew cannot detect the clash automatically. Pick one.

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
