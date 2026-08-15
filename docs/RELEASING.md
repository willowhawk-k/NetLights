# Releasing NetLights

**This is the one file to open when cutting a release.** Everything else — build details,
platform notes, the port plan — is reference. If a step here is wrong or missing, fix it
here rather than remembering the correction.

NetLights ships through **four channels** from one codebase:

| Channel | Artifact | Published to |
|---|---|---|
| Mac App Store | sandboxed `.app` | App Store Connect |
| Developer ID | notarized `.zip` | GitHub Releases |
| Homebrew | cask + formula | `willowhawk-k/homebrew-tap` |
| Linux | tarball, `.deb`, `.rpm`, AppImage | GitHub Releases (+ apt/yum repos) |

## At a glance

| # | Step | Where | Who | Time |
|---|---|---|---|---|
| 1 | Bump version, write notes | Mac | **You** | 10 min |
| 2 | Compile gates → then tag | **CI** | Automatic (you tag) | 5 min |
| 3 | Build all Linux artifacts, smoke-test, attest → draft release | **CI** | **Automatic** | 10 min |
| 4 | Notarized macOS build — **signature #1** | Mac | **You** | 10 min |
| 5 | Install-test on real Linux | Dell + VMs | **You** | 30 min |
| 6 | Verify provenance, build indexes, sign — **signature #2** | VM + Mac | **You** | 15 min |
| 7 | Publish: release → tap → repos → App Store (**signature #3**) | Mac | **You** | 5 min |
| 8 | Docs + memory | Both repos | **You** | 5 min |

**Only steps 2 and 3 are automated.** Everything else is yours, by design — every signature
and every publish is a decision, not a pipeline stage.

The long pole is step 5, and it is the one that cannot be automated away: CI proves the
software builds and runs, only a real machine proves a *package installs*.

## Where each thing runs

| Work | Runs on | Why there |
|---|---|---|
| Version bump, notes | Mac | — |
| Compile gates | CI | Unattended; catches the Core-as-a-real-module bug class |
| Linux artifacts | CI | Frees the Mac; the only place x86_64 gets executed |
| macOS signed build | **Mac only** | Developer ID cert lives in the keychain |
| Package install tests | **Linux hardware / VMs** | CI has no Bluetooth, USB, battery or Wi-Fi |
| Repo index generation | Any Linux (arch-independent) | `createrepo_c` is not packaged for macOS |
| GPG signing | **Mac only** | Key stays in 1Password — never in CI |
| Publishing | Mac | You decide what goes out |

**Three signatures, all yours, all local:** Developer ID (step 4), GPG (step 6), App Store
(step 7). CI signs nothing, ever.

---

## The guards — mistakes that stop themselves

You do not need to remember these. They fail the build with the fix in the message.

| Guard | Catches |
|---|---|
| `build-app.sh` version-drift check | `Version.swift` not bumped alongside `Version.xcconfig` — would ship a mislabelled Linux binary |
| `build-linux.sh` ELF/static/arch checks | Packaging a binary that is the wrong architecture or picked up a dynamic dependency |
| `build-linux.sh` re-extract check | A tarball whose contents differ from what was staged |
| `build-packages.sh` placeholder check | An unrendered `${NL_...}` reaching a package |
| `build-appimage.sh` runtime pin | Upstream republishing the AppImage runtime under its rolling tag |
| `build-appimage.sh` payload check | A concatenation that produced an unmountable AppImage |
| `gh attestation verify` (step 6a) | An artifact that did not come from your workflow at your commit |

---

## Step 1 — Bump and write *(Mac, ~10 min)*

1. `Version.xcconfig` — `MARKETING_VERSION`, and `CURRENT_PROJECT_VERSION` **must strictly
   exceed** the last build uploaded to App Store Connect. `NL_RELEASE_DATE` too.
2. `Sources/NetLightsCore/Version.swift` — same marketing version. Hand-maintained because
   Linux has no Info.plist and a SwiftPM manifest is host-evaluated.
3. `RELEASE-NOTES.md` — move anything shipped out of "Queued for 2.0" into the history.
4. `APPSTORE-LATEST.md` — What's New, reviewer notes (**4,000 char limit**, leave ~100
   spare), description if it changed. No hand-wrapping; App Store Connect wraps for you.
5. `README.md` — version badge.

Commit and push to `main`.

## Step 2 — Gates *(CI, ~5 min, unattended)*

The push runs: both Linux arches cross-compiled, macOS `swift build`, and the App Store
`xcodebuild -configuration Release` build.

That last one is not optional and not redundant. `swift build` does not apply the Xcode
target's settings, and this gap once produced a tagged release that could not be archived
at all.

Green → tag and push:

```bash
git tag -a v<version> -m "NetLights <version>" && git push origin v<version>
```

## Step 3 — Linux artifacts *(CI, ~10 min, unattended)*

The tag triggers the build of tarball, `.deb`, `.rpm` and AppImage for both architectures
and uploads all ~14 files to a **draft release**.

Draft, not published: hand-uploading that many files is where one quietly goes missing, but
nothing reaches the public releases page unreviewed. You add the macOS zip, check the list,
and publish in step 7.

To build them locally instead (all three are safe to re-run):

```bash
./scripts/build-linux.sh && ./scripts/build-packages.sh && ./scripts/build-appimage.sh
```

## Step 4 — macOS signed build *(Mac only, ~10 min)*

Nobody else can do this: the Developer ID certificate is in your keychain.

```bash
SIGN_IDENTITY="Developer ID Application: KEITH STEFAN WILLOWHAWK (2KU2Y7CKHS)" NOTARY_PROFILE="NetLights-notary" ./scripts/build-app.sh
```

**Signature #1 — Apple Developer ID.** Produces a signed, hardened-runtime, notarized,
stapled `dist/NetLights-<version>.zip`. Verify before going further:

```bash
codesign -dv --verbose=4 dist/NetLights.app 2>&1 | grep Authority
spctl -a -vvv dist/NetLights.app
xcrun stapler validate dist/NetLights.app
```

Expect `Developer ID Application`, `source=Notarized Developer ID`, and a passing staple.
If `codesign` says **adhoc**, you built without `SIGN_IDENTITY` — delete the zip and rebuild.
An ad-hoc zip sits at exactly the filename `gh release create` uploads.

## Step 5 — Validate on Linux *(hardware + VMs, ~30 min)*

**The real gate.** CI proves things build and start; only this proves they install and work.

Work through `.maintainer/VM-TASKS.md`. Do not skip on the grounds that "nothing Linux changed" —
the packaging scripts change more often than the collectors, and a broken package is
invisible until someone installs it.

## Step 6 — Sign the repo metadata *(Mac + a Linux box, ~15 min)*

**Signature #2 — yours.** Deliberately after step 5: by now you have seen these exact
artifacts install and run, so the signature means agreement rather than availability.

### What you are actually signing

There is no Linux equivalent of `codesign`. You do not sign the binary — you sign the
**repository indexes**, which is what `apt` and `dnf` verify:

| Repo | Signed file | Produces |
|---|---|---|
| APT | the `Release` file | `InRelease` (clearsigned) + `Release.gpg` (detached) |
| YUM/DNF | `repodata/repomd.xml` | `repomd.xml.asc` |

Each index lists a SHA256 for every package, so **one signature transitively covers all of
them**. Optionally also `rpm --addsign` the `.rpm`s — the RPM ecosystem expects
package-level signatures. Individual `.deb` signing is not worth doing; apt trusts the
repo, not the package.

### 6a. Verify provenance before signing anything

CI built these; you are about to vouch for them. Prove they came from your workflow at your
commit rather than trusting the download:

```bash
gh attestation verify dist/linux/netlights-<version>-x86_64.tar.gz --repo willowhawk-k/NetLights
```

Run it on every artifact you are about to sign. A failure here means stop — not "probably
fine".

### 6b. Generate the indexes

**Architecture does not matter for this step.** These tools read package headers and write
text files full of hashes; they never execute the packages, so an **arm64 machine can index
x86_64 packages perfectly well**. The UTM VM is enough. Only *install testing* (step 5)
needs matching architecture, which is what the Dell is for.

Where each tool can run:

| Tool | macOS | Linux |
|---|---|---|
| `dpkg-scanpackages` (APT) | ✅ `brew install dpkg` | ✅ |
| `aptly` (APT, alternative) | ✅ `brew install aptly` | ✅ |
| `createrepo_c` (YUM) | ❌ not packaged for macOS | ✅ |
| `gpg` | ✅ `brew install gnupg` | ✅ |

So the practical split is: **APT metadata can be produced on the Mac; YUM metadata needs a
Linux box** (any architecture). Generate the YUM indexes on the VM, copy the few KB of
`repodata/` back, and sign on the Mac — the key never goes near Linux.

### 6c. Sign

The signing subkey comes out of 1Password into a throwaway keyring, and goes away after.
1Password does not act as a GPG agent the way it does for SSH, so this is deliberate rather
than incidental:

```bash
export GNUPGHOME="$(mktemp -d)"
op document get "NetLights signing subkey" | gpg --batch --import
gpg --list-secret-keys
```

Then sign both indexes:

```bash
# APT
gpg --batch --yes --clearsign -o dist/repo/apt/dists/stable/InRelease dist/repo/apt/dists/stable/Release
gpg --batch --yes --detach-sign --armor -o dist/repo/apt/dists/stable/Release.gpg dist/repo/apt/dists/stable/Release

# YUM
gpg --batch --yes --detach-sign --armor dist/repo/yum/repodata/repomd.xml
```

And export the public key for users to trust:

```bash
gpg --armor --export "NetLights" > dist/repo/netlights.asc
```

Finally, discard the keyring:

```bash
rm -rf "${GNUPGHOME:?}" && unset GNUPGHOME
```

Only the **signing subkey** is ever needed here. The primary key stays offline, so a
compromise of this step costs a subkey rotation rather than the identity.

## Step 7 — Publish *(Mac, ~5 min)*

**Order matters.** Getting it wrong is user-visible.

1. **GitHub release** — macOS zip plus every Linux artifact and its hash:
   ```bash
   gh release create v<version> dist/NetLights-<version>.zip dist/linux/* --repo willowhawk-k/NetLights --title "NetLights <version>" --notes-file dist/RELEASE_v<version>.md
   ```
2. **Homebrew tap — after the release exists.** The cask URL points at the release asset,
   so pushing the tap first hands every user a 404.
   - Bump `version` + `sha256` in **both** `Casks/netlights.rb` (hash of the notarized zip)
     and `Formula/netlights-cli.rb` (hash of the tag tarball).
   - Verify each hash against its **live URL** before pushing — `brew audit [path]` no
     longer exists, and by-name auditing only works once the tap is pushed, so this is the
     last chance to catch a wrong hash:
     ```bash
     curl -sL <release-asset-url> | shasum -a 256
     curl -sL <tag-tarball-url> | shasum -a 256
     ```
   - `brew style` both files, copy into `~/Source/homebrew-tap` (the SSH working clone),
     commit, push.
   - Then audit by name — both print nothing and exit 0 on success:
     ```bash
     brew audit --cask willowhawk-k/tap/netlights && brew audit willowhawk-k/tap/netlights-cli
     ```
3. **apt/yum repos** — publish the signed metadata from step 6 to GitHub Pages.
4. **App Store** — archive and upload in Xcode, paste from `APPSTORE-LATEST.md`, submit.
   **Signature #3 — Apple, via Xcode.** Independent of everything above; review takes days,
   so it neither blocks nor is blocked by the other channels.

## Step 8 — Post-release *(both repos, ~5 min)*

- Public repo: any docs the release changed.
- `NetLights-private`: the release record in memory — version, date, both hashes, anything
  that cost time this round.
- Push both.

---

## Variant: macOS-only patch

Most releases. Steps 1, 2, 4, 7.1, 7.2, 7.4, 8 — skip all Linux work and the GPG signing.
Still bump `Version.swift`; the guard will stop you anyway.

## Variant: Linux-only patch

Steps 1, 2, 3, 5, 6, 7.1, 7.3, 8. No notarization, no App Store, no Homebrew.

---

## If something goes wrong

**Tagged too early.** Tags are movable until someone has pulled them. Delete locally and
remotely, re-tag, force-push. Do this immediately or not at all.

**Published a bad hash in the tap.** Fix and push the tap again — it is just a git repo,
and users get the fix on their next `brew update`.

**Notarization rejected.** The log URL in the `notarytool` output says why. Almost always a
missing hardened-runtime flag or an unsigned nested binary.

**App Store build number collision.** `CURRENT_PROJECT_VERSION` must *strictly* exceed every
prior upload — including builds you uploaded and never submitted.
