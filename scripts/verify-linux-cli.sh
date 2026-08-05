#!/usr/bin/env sh
# Verify the NetLights Linux CLI on a real machine. Run it ON the Linux VM:
#   chmod +x verify-linux-cli.sh && ./verify-linux-cli.sh ./netlights
#
# Don't run this on macOS: section 7 binds 0.0.0.0, which raises the macOS Application
# Firewall prompt and blocks the process until someone clicks it, so the script just hangs.
#
# Covers everything that can be checked non-interactively. The two things it cannot
# check — that the live TUI paints and that your terminal is restored afterwards —
# are printed as manual steps at the end.
set -u
BIN="${1:-./netlights}"
pass=0; fail=0
ok()   { echo "  PASS  $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail+1)); }

echo "== NetLights Linux CLI verification =="
echo "binary: $BIN"
# Distinguish "no such file" from "exists but not executable". Reporting a missing path as
# "not executable" sends you off checking chmod when the real cause is usually a typo in the
# argument — a stray character on the path is invisible until the two cases are separated.
if [ ! -e "$BIN" ]; then
    echo "no such file: $BIN"
    case "$BIN" in
        *[!A-Za-z0-9._/-]*) echo "  (the path contains an unusual character — check for a typo)" ;;
    esac
    [ -e "${BIN%?}" ] && echo "  did you mean: ${BIN%?}"
    exit 1
fi
[ -x "$BIN" ] || { echo "not executable: $BIN  (try: chmod +x '$BIN')"; exit 1; }
echo

echo "-- 1. fully static (no runtime deps: the whole portability claim) --"
if command -v ldd >/dev/null 2>&1; then
    out=$(ldd "$BIN" 2>&1 || true)
    case "$out" in
        *"not a dynamic executable"*|*"statically linked"*) ok "ldd: static" ;;
        *) bad "ldd reports dynamic linkage: $out" ;;
    esac
else
    ok "ldd absent (musl image) — skipping"
fi

echo "-- 2. version / help --"
"$BIN" --version >/dev/null 2>&1 && ok "--version" || bad "--version"
"$BIN" --help | grep -q "netlights tui" && ok "--help lists tui" || bad "--help"

echo "-- 3. snapshot JSON is valid and populated --"
"$BIN" --dump-json > /tmp/nl-snap.json 2>/dev/null
if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY' && ok "--dump-json parses, has interfaces" || bad "--dump-json"
import json,sys
d=json.load(open('/tmp/nl-snap.json'))
assert d.get('interfaces'), 'no interfaces'
assert 'schemaVersion' in d, 'no schemaVersion'
print('       interfaces=%d routes=%d gateways=%d'%(
    len(d['interfaces']),len(d.get('routes',[])),len(d.get('gateways',[]))))
PY
else
    [ -s /tmp/nl-snap.json ] && ok "--dump-json produced output" || bad "--dump-json empty"
fi

echo "-- 4. TUI renders every view without a terminal (--once) --"
for v in graph routes interfaces devices dns; do
    if COLUMNS=100 LINES=30 "$BIN" tui --once --view "$v" 2>/dev/null | grep -q NetLights; then
        ok "tui --once --view $v"
    else
        bad "tui --once --view $v"
    fi
done

echo "-- 5. TUI refuses a non-tty for the INTERACTIVE mode (no escape-code vomit) --"
if "$BIN" tui < /dev/null > /tmp/nl-tui.out 2>/tmp/nl-tui.err; then
    bad "interactive tui should have refused without a tty"
else
    grep -q "needs an interactive terminal" /tmp/nl-tui.err \
        && ok "refuses politely with a pointer to --dump-json/serve" \
        || bad "wrong error: $(head -1 /tmp/nl-tui.err)"
fi

# Wait for the server's startup banner. Match EITHER wording: a loopback bind says
# "serving on", a routable one says "listening on". (Grepping only for "serving on" is
# what made the --bind all check below spin for 30s and then wrongly fail.)
wait_for_banner() {
    i=0
    while [ $i -lt 50 ]; do
        grep -qiE "serving on|listening on" "$1" 2>/dev/null && return 0
        i=$((i+1))
        command -v usleep >/dev/null 2>&1 && usleep 200000 || sleep 1
    done
    return 1
}

echo "-- 6. serve binds LOOPBACK by default (not the LAN) --"
"$BIN" serve --port 8791 > /tmp/nl-serve.log 2>&1 &
SRV=$!
wait_for_banner /tmp/nl-serve.log || bad "server never printed a startup banner"
if command -v ss >/dev/null 2>&1; then
    if ss -lnt 2>/dev/null | grep -q "127.0.0.1:8791"; then ok "listening on 127.0.0.1:8791"
    elif ss -lnt 2>/dev/null | grep -q "0.0.0.0:8791"; then bad "listening on 0.0.0.0 — loopback default broken!"
    else bad "not listening on 8791"; fi
fi
if command -v curl >/dev/null 2>&1; then
    curl -s --max-time 5 http://127.0.0.1:8791/snapshot.json | grep -q interfaces \
        && ok "/snapshot.json over loopback" || bad "/snapshot.json"
    curl -s --max-time 5 http://127.0.0.1:8791/graph.svg | grep -q "<svg" \
        && ok "/graph.svg renders" || bad "/graph.svg"
    curl -s --max-time 5 http://127.0.0.1:8791/ | grep -q "NetLights" \
        && ok "/ serves the web UI" || bad "/"
    curl -s --max-time 5 -H 'Host: evil.example' http://127.0.0.1:8791/snapshot.json \
        | grep -q "unrecognized Host" && ok "DNS-rebinding guard rejects a bogus Host" \
        || bad "rebinding guard did NOT reject a bogus Host"
fi
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null

echo "-- 7. a routable bind warns loudly, and says so honestly --"
"$BIN" serve --port 8792 --bind all > /tmp/nl-serve2.log 2>&1 &
SRV2=$!
wait_for_banner /tmp/nl-serve2.log || bad "server never printed a startup banner"
# -i: the warning begins a sentence ("Reachable from your network"), so a case-sensitive
# match here is a false failure waiting to happen.
grep -qi "reachable from your network" /tmp/nl-serve2.log \
    && ok "--bind all prints the exposure warning" \
    || bad "no warning on --bind all: $(head -2 /tmp/nl-serve2.log)"
# The banner must report what was ACTUALLY bound — printing a loopback URL while on
# 0.0.0.0 is how "--bind is being ignored" gets misdiagnosed.
grep -q "0.0.0.0" /tmp/nl-serve2.log \
    && ok "banner names the real bind address" \
    || bad "banner doesn't mention 0.0.0.0"
if command -v ss >/dev/null 2>&1; then
    ss -lnt 2>/dev/null | grep -q "0.0.0.0:8792" \
        && ok "--bind all really listens on 0.0.0.0" \
        || bad "--bind all did NOT bind 0.0.0.0"
fi
kill $SRV2 2>/dev/null; wait $SRV2 2>/dev/null

echo "-- 8. bad input is a usage error, not a crash --"
"$BIN" serve --port 99999 >/dev/null 2>&1; [ $? -eq 2 ] && ok "bad --port exits 2" || bad "bad --port"
"$BIN" tui --nonsense >/dev/null 2>&1;   [ $? -eq 2 ] && ok "unknown option exits 2" || bad "unknown option"

echo "-- 9. near-miss args are REJECTED, never silently ignored (regression) --"
# '--serve --bind all' used to fall through to the default mode and quietly bind
# loopback with --bind discarded. An unrecognized argument must now be an error.
out=$("$BIN" --serve --bind all 2>&1); rc=$?
if [ $rc -eq 2 ] && echo "$out" | grep -q "did you mean 'serve'"; then
    ok "--serve rejected with a suggestion"
else
    bad "--serve was not rejected (rc=$rc): $out"
fi
out=$("$BIN" --tui 2>&1); rc=$?
[ $rc -eq 2 ] && ok "--tui rejected" || bad "--tui not rejected"
out=$("$BIN" bogus-subcommand 2>&1); rc=$?
[ $rc -eq 2 ] && ok "unknown subcommand rejected (no GUI to fall back to)" \
              || bad "unknown subcommand silently accepted (rc=$rc)"

echo
echo "== $pass passed, $fail failed =="
cat <<'EOM'

MANUAL (needs a real terminal — please eyeball these):
  1. ./netlights tui
       - does it paint, and refresh about once a second?
       - press g r i d n and 1-5: do the views switch?
       - press h (hide inactive), p (privacy — addresses masked), SPACE (pause)
       - RESIZE the window: does the layout follow?
       - press q: does your shell come back NORMAL (echo works, no stray colours)?
  2. ./netlights tui  then Ctrl-C  -> terminal must also be restored.
  3. ./netlights tui  then Ctrl-Z  -> shell restored; `fg` resumes cleanly.
  4. Over SSH from the Mac: ssh <vm> then run tui there (the real use case).
  5. LANG=C ./netlights tui --once   -> ASCII fallback, no mojibake.
EOM
[ $fail -eq 0 ] || exit 1
