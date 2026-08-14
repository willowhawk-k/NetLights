# Shared helpers for the build scripts. Sourced, never executed.
#
# These exist because the same scripts now run on two hosts with different userlands: the
# developer's Mac (BSD) and CI's Ubuntu runners (GNU coreutils). Where the two disagree,
# the difference is isolated here rather than scattered through the scripts.

# sha256 of one or more files, printed as "<hash>  <name>".
#
# macOS ships `shasum` (perl); Linux ships `sha256sum` natively and usually both. The two
# produce identical output format, so callers do not care which ran.
nl_sha256() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$@"
    else
        sha256sum "$@"
    fi
}

# Epoch seconds -> the [[CC]YY]MMDDhhmm.SS form that `touch -t` expects.
#
# `date -r` means "this is epoch seconds" on BSD and "reference this FILE" on GNU — the
# same invocation quietly means two different things, and on Linux the BSD form fails with
# "cannot stat '1754...'". Try BSD, fall back to GNU's @epoch syntax.
#
# UTC deliberately: without -u the stamp depends on the builder's timezone, which would
# make the artifact hash differ between a Mac in MDT and a runner in UTC. Reproducibility
# across hosts is the whole point of pinning timestamps at all.
nl_touch_stamp() {
    date -u -r "$1" +%Y%m%d%H%M.%S 2>/dev/null || date -u -d "@$1" +%Y%m%d%H%M.%S
}
