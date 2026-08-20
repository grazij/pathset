#!/usr/bin/env bash
# Literal '~' and '$VAR' strings are written into config files on purpose, for
# pathset itself to expand. Shellcheck's expansion warnings don't apply here.
# shellcheck disable=SC2088,SC2016
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$DIR/pathset"

if [[ ! -x "$BIN" ]]; then
	echo "tests: $BIN not found or not executable; run 'make build' first" >&2
	exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pathset-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
selected=0
total=0

# Optional filter:  ./tests/run.sh [-l] [PATTERN]
#
#   -l         list the tests and exit
#   PATTERN    a test number, or a case-insensitive substring of its name
#
# Every block still executes even when filtered. Fixtures are created inline
# and later blocks reuse earlier ones (test 11 uses the config test 9 wrote),
# so skipping code would break the suite. The filter decides which assertions
# are reported and counted -- what you want when iterating on one case. It is
# not a speed optimisation; the whole suite runs in well under a second.
LIST=0
FILTER=""
case "${1:-}" in
	-l|--list) LIST=1 ;;
	"") ;;
	-*) echo "usage: $0 [-l] [PATTERN]" >&2; exit 2 ;;
	*) FILTER="$1" ;;
esac

CUR_ON=1

# Open a test block. Every block calls this before asserting.
t() {
	total=$((total + 1))
	if [[ $LIST -eq 1 ]]; then
		printf '%3s  %s\n' "$1" "$2"
		CUR_ON=0
		return 0
	fi
	if [[ -z "$FILTER" ]]; then
		CUR_ON=1
	else
		# Contained: nocasematch would otherwise leak into the tests' own
		# path comparisons and make a failing one match.
		shopt -s nocasematch
		if [[ "$1" == "$FILTER" || "$2" == *"$FILTER"* ]]; then
			CUR_ON=1
		else
			CUR_ON=0
		fi
		shopt -u nocasematch
	fi
	[[ $CUR_ON -eq 1 ]] && selected=$((selected + 1))
	return 0
}

ok() {
	[[ $CUR_ON -eq 1 ]] || return 0
	printf '  ok  %s\n' "$1"
	pass=$((pass + 1))
	return 0
}

bad() {
	[[ $CUR_ON -eq 1 ]] || return 0
	printf '  FAIL %s\n' "$1"
	[[ -n "${2:-}" ]] && printf '       %s\n' "$2"
	fail=$((fail + 1))
	return 0
}

# Three real, populated dirs to use as valid PATH entries.
A="$WORK/a"; B="$WORK/b"; C="$WORK/c"
mkdir -p "$A" "$B" "$C"
: >"$A/file"; : >"$B/file"; : >"$C/file"

# --- Test 1: basic parse with comments and blanks ---
t 1 'basic parse with comments and blanks'
cfg1="$WORK/cfg1"
cat >"$cfg1" <<EOF
# leading comment
$A

   $B
	# indented comment with tab
$C
EOF

expected1="$A:$B:$C"
got1="$("$BIN" -f "$cfg1" 2>/dev/null)"
if [[ "$got1" == "$expected1" ]]; then
	ok "basic parsing strips comments and blanks"
else
	bad "basic parsing" "expected: $expected1 / got: $got1"
fi

# --- Test 2: empty file is refused unless --allow-empty ---
t 2 'empty file is refused unless --allow-empty'
cfg2="$WORK/cfg2"
: >"$cfg2"
got2="$("$BIN" -f "$cfg2" 2>"$WORK/err2")"
rc2=$?
if [[ -z "$got2" && $rc2 -eq 1 ]] && grep -q -- '--allow-empty' "$WORK/err2"; then
	ok "empty config is refused (exit 1) and names --allow-empty"
else
	bad "empty config" "rc=$rc2 got: $got2 err: $(cat "$WORK/err2")"
fi

# --- Test 3: missing file -> non-zero exit, stderr message ---
t 3 'missing file -> non-zero exit, stderr message'
if "$BIN" -f "$WORK/does-not-exist" >/dev/null 2>"$WORK/err"; then
	bad "missing file should error"
else
	if grep -q "cannot open" "$WORK/err"; then
		ok "missing file errors with non-zero and stderr message"
	else
		bad "missing file stderr" "stderr: $(cat "$WORK/err")"
	fi
fi

# --- Test 4: -f with no argument -> exit 2 ---
t 4 '-f with no argument -> exit 2'
"$BIN" -f >/dev/null 2>"$WORK/err"
rc=$?
if [[ $rc -eq 2 ]]; then
	ok "-f with no arg exits 2"
else
	bad "-f with no arg" "rc=$rc"
fi

# --- Test 5: XDG_CONFIG_HOME fallback (no -f) ---
t 5 'XDG_CONFIG_HOME fallback (no -f)'
xdg="$WORK/xdg"
mkdir -p "$xdg/pathset"
echo "$A" >"$xdg/pathset/path"
got5="$(env -i HOME="$WORK/home" XDG_CONFIG_HOME="$xdg" "$BIN" 2>/dev/null)"
if [[ "$got5" == "$A" ]]; then
	ok "XDG_CONFIG_HOME/pathset/path fallback"
else
	bad "XDG fallback" "got: $got5"
fi

# --- Test 6: HOME fallback when XDG_CONFIG_HOME unset ---
t 6 'HOME fallback when XDG_CONFIG_HOME unset'
home="$WORK/home"
mkdir -p "$home/.pathset"
echo "$B" >"$home/.pathset/path"
got6="$(env -i HOME="$home" "$BIN" 2>/dev/null)"
if [[ "$got6" == "$B" ]]; then
	ok "HOME/.pathset/path fallback"
else
	bad "HOME fallback" "got: $got6"
fi

# --- Test 7: XDG takes precedence over HOME ---
t 7 'XDG takes precedence over HOME'
got7="$(env -i HOME="$home" XDG_CONFIG_HOME="$xdg" "$BIN" 2>/dev/null)"
if [[ "$got7" == "$A" ]]; then
	ok "XDG_CONFIG_HOME precedes HOME"
else
	bad "XDG precedence" "got: $got7"
fi

# --- Test 8: CRLF tolerance ---
t 8 'CRLF tolerance'
cfg8="$WORK/cfg8"
printf '%s\r\n%s\r\n' "$A" "$B" >"$cfg8"
got8="$("$BIN" -f "$cfg8" 2>/dev/null)"
if [[ "$got8" == "$A:$B" ]]; then
	ok "CRLF line endings tolerated"
else
	bad "CRLF" "got: $got8"
fi

# --- Test 9: missing directory is emitted with a warning ---
t 9 'missing directory is emitted with a warning'
cfg9="$WORK/cfg9"
missing="$WORK/no-such-dir"
cat >"$cfg9" <<EOF
$A
$missing
$B
EOF
got9="$("$BIN" -f "$cfg9" 2>"$WORK/err9")"
rc9=$?
if [[ "$got9" == "$A:$missing:$B" && $rc9 -eq 0 ]] \
	&& grep -q "'$missing' does not exist (emitted anyway)" "$WORK/err9"; then
	ok "missing directory is emitted with a warning (exit 0)"
else
	bad "missing dir emit" "rc=$rc9 got: $got9 / err: $(cat "$WORK/err9")"
fi

# --- Test 10: empty directory is emitted with a warning ---
t 10 'empty directory is emitted with a warning'
empty="$WORK/empty"
mkdir -p "$empty"
cfg10="$WORK/cfg10"
cat >"$cfg10" <<EOF
$A
$empty
$B
EOF
got10="$("$BIN" -f "$cfg10" 2>"$WORK/err10")"
rc10=$?
if [[ "$got10" == "$A:$empty:$B" && $rc10 -eq 0 ]] \
	&& grep -q "'$empty' is an empty directory (emitted anyway)" "$WORK/err10"; then
	ok "empty directory is emitted with a warning (exit 0)"
else
	bad "empty dir emit" "rc=$rc10 got: $got10 / err: $(cat "$WORK/err10")"
fi

# --- Test 11: -q suppresses per-entry warnings but keeps a summary ---
t 11 '-q suppresses per-entry warnings but keeps a summary'
got11="$("$BIN" -f "$cfg9" -q 2>"$WORK/err11")"
if [[ "$got11" == "$A:$missing:$B" ]] \
	&& ! grep -q 'emitted anyway' "$WORK/err11" \
	&& grep -q '1 entry emitted with a warning' "$WORK/err11"; then
	ok "-q suppresses per-entry warnings but still summarizes"
else
	bad "-q suppress" "got: $got11 / err: $(cat "$WORK/err11")"
fi

# --- Test 12: file (not a directory) is emitted with a warning ---
t 12 'file (not a directory) is emitted with a warning'
filepath="$WORK/regular-file"
: >"$filepath"
cfg12="$WORK/cfg12"
cat >"$cfg12" <<EOF
$A
$filepath
EOF
got12="$("$BIN" -f "$cfg12" 2>"$WORK/err12")"
if [[ "$got12" == "$A:$filepath" ]] \
	&& grep -q "'$filepath' is not a directory (emitted anyway)" "$WORK/err12"; then
	ok "non-directory is emitted with a warning"
else
	bad "non-dir emit" "got: $got12 / err: $(cat "$WORK/err12")"
fi

# --- Test 13: duplicate entries are dropped, first wins ---
t 13 'duplicate entries are dropped, first wins'
cfg13="$WORK/cfg13"
cat >"$cfg13" <<EOF
$A
$B
$A
$C
$B
EOF
got13="$("$BIN" -f "$cfg13" 2>/dev/null)"
if [[ "$got13" == "$A:$B:$C" ]]; then
	ok "duplicates dropped, first occurrence preserved"
else
	bad "dedup" "got: $got13"
fi

# --- Test 14: -d is no longer an option ---
t 14 '-d is no longer an option'
"$BIN" -f "$cfg13" -d >/dev/null 2>"$WORK/err14"
rc14=$?
if [[ $rc14 -eq 2 ]] && grep -q 'unknown argument: -d' "$WORK/err14"; then
	ok "-d is rejected: dedup is unconditional, not a flag"
else
	bad "-d removed" "rc=$rc14 err: $(cat "$WORK/err14")"
fi

# --- Test 15: dedup combined with a ?conditional drop ---
t 15 'dedup combined with a ?conditional drop'
cfg15="$WORK/cfg15"
cat >"$cfg15" <<EOF
$A
?$WORK/no-such
$A
$B
EOF
got15="$("$BIN" -f "$cfg15" 2>/dev/null)"
if [[ "$got15" == "$A:$B" ]]; then
	ok "dedup runs after filter; dropped entries don't shadow real ones"
else
	bad "dedup + filter" "got: $got15"
fi

# --- Test 16: -v prints kept entries on stderr ---
t 16 '-v prints kept entries on stderr'
cfg16="$WORK/cfg16"
cat >"$cfg16" <<EOF
$A
$B
EOF
got16="$("$BIN" -f "$cfg16" -v 2>"$WORK/err16")"
if [[ "$got16" == "$A:$B" ]] && \
   grep -q "keeping '$A'" "$WORK/err16" && \
   grep -q "keeping '$B'" "$WORK/err16"; then
	ok "-v prints kept entries on stderr"
else
	bad "-v keeps" "got: $got16 / err: $(cat "$WORK/err16")"
fi

# --- Test 17: -v is additive with the emitted-anyway warnings ---
t 17 '-v is additive with the emitted-anyway warnings'
cfg17="$WORK/cfg17"
cat >"$cfg17" <<EOF
$A
$WORK/no-such
EOF
"$BIN" -f "$cfg17" -v >/dev/null 2>"$WORK/err17"
if grep -q "keeping '$A'" "$WORK/err17" && \
   grep -q "keeping '$WORK/no-such'" "$WORK/err17" && \
   grep -q "'$WORK/no-such' does not exist (emitted anyway)" "$WORK/err17"; then
	ok "-v lists a warned entry as kept, alongside its warning"
else
	bad "-v additive" "err: $(cat "$WORK/err17")"
fi

# --- Test 18: -q overrides -v, leaving only the summary ---
t 18 '-q overrides -v, leaving only the summary'
"$BIN" -f "$cfg17" -v -q >/dev/null 2>"$WORK/err18"
if ! grep -qE 'keeping|expanded|skipping|emitted anyway' "$WORK/err18" \
	&& grep -q '1 entry emitted with a warning' "$WORK/err18"; then
	ok "-q overrides -v (only the summary survives)"
else
	bad "-q overrides -v" "err: $(cat "$WORK/err18")"
fi

# --- Test 19: -v reports dropped duplicates ---
t 19 '-v reports dropped duplicates'
cfg19="$WORK/cfg19"
cat >"$cfg19" <<EOF
$A
$B
$A
EOF
got19="$("$BIN" -f "$cfg19" -v 2>"$WORK/err19")"
if [[ "$got19" == "$A:$B" ]] && grep -q "dropping duplicate '$A'" "$WORK/err19"; then
	ok "-v reports dropped duplicates"
else
	bad "-v + dedup" "got: $got19 / err: $(cat "$WORK/err19")"
fi

# --- Test 20: ~/sub expands using $HOME ---
t 20 '~/sub expands using $HOME'
fakehome="$WORK/home2"
mkdir -p "$fakehome/bin"
: >"$fakehome/bin/file"
cfg20="$WORK/cfg20"
echo '~/bin' >"$cfg20"
got20="$(HOME="$fakehome" "$BIN" -f "$cfg20" 2>/dev/null)"
if [[ "$got20" == "$fakehome/bin" ]]; then
	ok "~/sub expands via \$HOME"
else
	bad "tilde expand" "got: $got20"
fi

# --- Test 21: \$VAR expansion ---
t 21 '\$VAR expansion'
cfg21="$WORK/cfg21"
echo '$MY_TEST_DIR/sub' >"$cfg21"
testdir="$WORK/vartest"
mkdir -p "$testdir/sub"
: >"$testdir/sub/file"
got21="$(MY_TEST_DIR="$testdir" "$BIN" -f "$cfg21" 2>/dev/null)"
if [[ "$got21" == "$testdir/sub" ]]; then
	ok "\$VAR expansion"
else
	bad "var expand" "got: $got21"
fi

# --- Test 22: \${VAR} braced expansion ---
t 22 '\${VAR} braced expansion'
cfg22="$WORK/cfg22"
echo '${MY_TEST_DIR}/sub' >"$cfg22"
got22="$(MY_TEST_DIR="$testdir" "$BIN" -f "$cfg22" 2>/dev/null)"
if [[ "$got22" == "$testdir/sub" ]]; then
	ok "\${VAR} braced expansion"
else
	bad "braced var expand" "got: $got22"
fi

# --- Test 23: unset var -> skip with warning ---
t 23 'unset var -> skip with warning'
cfg23="$WORK/cfg23"
cat >"$cfg23" <<EOF
$A
\$PATHSET_DEFINITELY_UNSET_XYZ/bin
EOF
got23="$(unset PATHSET_DEFINITELY_UNSET_XYZ; "$BIN" -f "$cfg23" 2>"$WORK/err23")"
if [[ "$got23" == "$A" ]] && grep -q "PATHSET_DEFINITELY_UNSET_XYZ is not set" "$WORK/err23"; then
	ok "unset \$VAR is skipped with warning"
else
	bad "unset var" "got: $got23 / err: $(cat "$WORK/err23")"
fi

# --- Test 24: unknown ~user -> skip with warning ---
t 24 'unknown ~user -> skip with warning'
cfg24="$WORK/cfg24"
cat >"$cfg24" <<EOF
$A
~pathset_no_such_user_xyz/bin
EOF
got24="$("$BIN" -f "$cfg24" 2>"$WORK/err24")"
if [[ "$got24" == "$A" ]] && grep -q "unknown user" "$WORK/err24"; then
	ok "unknown ~user is skipped with warning"
else
	bad "unknown user" "got: $got24 / err: $(cat "$WORK/err24")"
fi

# --- Test 25: tilde mid-string is literal ---
t 25 'tilde mid-string is literal'
cfg25="$WORK/cfg25"
echo "$WORK/~mid/foo" >"$cfg25"
"$BIN" -f "$cfg25" >/dev/null 2>"$WORK/err25"
if grep -q "'$WORK/~mid/foo' does not exist" "$WORK/err25"; then
	ok "tilde mid-string treated literally (not expanded)"
else
	bad "mid-tilde literal" "err: $(cat "$WORK/err25")"
fi

# --- Test 26: -v reports expansion ---
t 26 '-v reports expansion'
cfg26="$WORK/cfg26"
echo '~/bin' >"$cfg26"
HOME="$fakehome" "$BIN" -f "$cfg26" -v >/dev/null 2>"$WORK/err26"
if grep -q "expanded '~/bin' -> '$fakehome/bin'" "$WORK/err26"; then
	ok "-v reports expansions"
else
	bad "-v expansion" "err: $(cat "$WORK/err26")"
fi

# --- Test 27: HOME unset -> ~/x skipped with warning ---
t 27 'HOME unset -> ~/x skipped with warning'
cfg27="$WORK/cfg27"
echo '~/bin' >"$cfg27"
env -i "$BIN" -f "$cfg27" >/dev/null 2>"$WORK/err27"
if grep -q "HOME is not set" "$WORK/err27"; then
	ok "~/sub is skipped when \$HOME unset"
else
	bad "HOME unset" "err: $(cat "$WORK/err27")"
fi

# --- Test 28: full literal path with embedded $ that doesn't match a var pattern ---
t 28 'full literal path with embedded $ that doesn'\''t match a var pattern'
cfg28="$WORK/cfg28"
literal="$WORK/with\$dollar"
mkdir -p "$literal"
: >"$literal/file"
echo "$WORK/with\$/foo" >"$cfg28"
# $/ does not match a var pattern (next char is /, not [A-Za-z_]) so $ is literal
"$BIN" -f "$cfg28" >/dev/null 2>"$WORK/err28"
# That literal path doesn't exist, so it warns — and the warning should name
# the original (literal $) form, proving no expansion happened.
if grep -q "'$WORK/with\$/foo' does not exist" "$WORK/err28"; then
	ok "lone \$ followed by non-name char is literal"
else
	bad "lone \$" "err: $(cat "$WORK/err28")"
fi

# --- Test 29: clean run exits 0 ---
t 29 'clean run exits 0'
cfg31="$WORK/cfg31"
cat >"$cfg31" <<EOF
$A
$B
EOF
"$BIN" -f "$cfg31" >/dev/null 2>/dev/null
rc=$?
if [[ $rc -eq 0 ]]; then
	ok "clean run exits 0"
else
	bad "exit 0 clean" "rc=$rc"
fi

# --- Test 30: a failed directory check emits and leaves the exit code at 0 ---
t 30 'a failed directory check emits and leaves the exit code at 0'
cfg32="$WORK/cfg32"
cat >"$cfg32" <<EOF
$A
$WORK/no-such-dir
EOF
got32="$("$BIN" -f "$cfg32" 2>/dev/null)"
rc=$?
if [[ "$got32" == "$A:$WORK/no-such-dir" && $rc -eq 0 ]]; then
	ok "the directory check never produces exit 3"
else
	bad "filter exit code" "rc=$rc got: $got32"
fi

# --- Test 31: skipped expansion (unset var) exits 3 ---
t 31 'skipped expansion (unset var) exits 3'
cfg33="$WORK/cfg33"
cat >"$cfg33" <<EOF
$A
\$PATHSET_NOPE_X/bin
EOF
unset PATHSET_NOPE_X
"$BIN" -f "$cfg33" >/dev/null 2>/dev/null
rc=$?
if [[ $rc -eq 3 ]]; then
	ok "skipped entry (expand) exits 3"
else
	bad "exit 3 expand" "rc=$rc"
fi

# --- Test 32: -q does not change exit code ---
t 32 '-q does not change exit code'
"$BIN" -f "$cfg33" -q >/dev/null 2>/dev/null
rc=$?
if [[ $rc -eq 3 ]]; then
	ok "-q does not mask exit 3"
else
	bad "-q + exit" "rc=$rc"
fi

# --- Test 33: a deduped run with no skips exits 0 ---
t 33 'a deduped run with no skips exits 0'
cfg35="$WORK/cfg35"
cat >"$cfg35" <<EOF
$A
$A
$B
EOF
"$BIN" -f "$cfg35" >/dev/null 2>/dev/null
rc=$?
if [[ $rc -eq 0 ]]; then
	ok "dedup does not count as skip (exit 0)"
else
	bad "dedup exit" "rc=$rc"
fi

# --- Test 34: bundled flags (-qv) ---
t 34 'bundled flags (-qv)'
cfg36="$WORK/cfg36"
cat >"$cfg36" <<EOF
$A
$A
$B
EOF
got36="$("$BIN" -f "$cfg36" -qv 2>"$WORK/err36")"
if [[ "$got36" == "$A:$B" ]] && [[ ! -s "$WORK/err36" ]]; then
	ok "bundled short flags (-qv); -q still wins over -v"
else
	bad "bundled flags" "got: $got36 / err: $(cat "$WORK/err36")"
fi

# --- Test 35: unknown flag exits 2 ---
t 35 'unknown flag exits 2'
"$BIN" -Z >/dev/null 2>"$WORK/err37"
rc=$?
if [[ $rc -eq 2 ]] && grep -q "unknown argument" "$WORK/err37"; then
	ok "unknown flag exits 2"
else
	bad "unknown flag" "rc=$rc / err: $(cat "$WORK/err37")"
fi

# --- Test 36: positional argument is rejected ---
t 36 'positional argument is rejected'
"$BIN" extra-arg >/dev/null 2>"$WORK/err36pos"
rc=$?
if [[ $rc -eq 2 ]] && grep -q "unexpected argument" "$WORK/err36pos"; then
	ok "positional argument is rejected"
else
	bad "positional arg" "rc=$rc / err: $(cat "$WORK/err36pos")"
fi

# --- Test 37: -V prints version and exits 0 ---
t 37 '-V prints version and exits 0'
got39="$("$BIN" -V 2>/dev/null)"
rc=$?
if [[ $rc -eq 0 ]] && [[ "$got39" =~ ^pathset\ [0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	ok "-V prints version (matches 'pathset X.Y.Z')"
else
	bad "-V" "rc=$rc / got: $got39"
fi

# --- Test 38: ?conditional missing dir -> silent drop, exit 0 ---
t 38 '?conditional missing dir -> silent drop, exit 0'
cfg38="$WORK/cfg38"
cat >"$cfg38" <<EOF
$A
?$WORK/no-such-optional
EOF
got38="$("$BIN" -f "$cfg38" 2>"$WORK/err38")"
rc=$?
if [[ "$got38" == "$A" ]] && [[ ! -s "$WORK/err38" ]] && [[ $rc -eq 0 ]]; then
	ok "?conditional missing dir is silently dropped (exit 0)"
else
	bad "?conditional silent" "got: $got38 / rc=$rc / err: $(cat "$WORK/err38")"
fi

# --- Test 39: ?conditional + -v reports the drop ---
t 39 '?conditional + -v reports the drop'
"$BIN" -f "$cfg38" -v >/dev/null 2>"$WORK/err39"
if grep -q "skipping conditional '$WORK/no-such-optional'" "$WORK/err39"; then
	ok "?conditional drop reported under -v"
else
	bad "?conditional verbose" "err: $(cat "$WORK/err39")"
fi

# --- Test 40: ?conditional with unset var also silent ---
t 40 '?conditional with unset var also silent'
cfg40="$WORK/cfg40"
cat >"$cfg40" <<EOF
$A
?\$PATHSET_DEFINITELY_UNSET_OPT/bin
EOF
got40="$(unset PATHSET_DEFINITELY_UNSET_OPT; "$BIN" -f "$cfg40" 2>"$WORK/err40")"
rc=$?
if [[ "$got40" == "$A" ]] && [[ ! -s "$WORK/err40" ]] && [[ $rc -eq 0 ]]; then
	ok "?conditional with unset var is silent (exit 0)"
else
	bad "?conditional unset var" "got: $got40 / rc=$rc / err: $(cat "$WORK/err40")"
fi

# --- Test 41: ?conditional that DOES pass the check behaves normally ---
t 41 '?conditional that DOES pass the check behaves normally'
cfg41="$WORK/cfg41"
cat >"$cfg41" <<EOF
?$A
$B
EOF
got41="$("$BIN" -f "$cfg41" 2>/dev/null)"
rc=$?
if [[ "$got41" == "$A:$B" ]] && [[ $rc -eq 0 ]]; then
	ok "?conditional that passes the check is included normally"
else
	bad "?conditional resolves" "got: $got41 / rc=$rc"
fi

# --- Test 42: ?conditional with whitespace between ? and path ---
t 42 '?conditional with whitespace between ? and path'
cfg42="$WORK/cfg42"
cat >"$cfg42" <<EOF
?  $A
EOF
got42="$("$BIN" -f "$cfg42" 2>/dev/null)"
if [[ "$got42" == "$A" ]]; then
	ok "?conditional accepts whitespace between ? and path"
else
	bad "?conditional whitespace" "got: $got42"
fi

# --- Test 43: permission-denied directory is emitted with a warning ---
t 43 'permission-denied directory is emitted with a warning'
noperm="$WORK/noperm"
mkdir -p "$noperm"
chmod 000 "$noperm"
# Ensure cleanup so trap can rm -rf
trap 'chmod 755 "$noperm" 2>/dev/null; rm -rf "$WORK"' EXIT
cfg43="$WORK/cfg43"
cat >"$cfg43" <<EOF
$A
$noperm
EOF
got43="$("$BIN" -f "$cfg43" 2>"$WORK/err43")"
rc=$?
# Behavior: stat() succeeds (we can stat the dir we own) but opendir() fails
# with EACCES. Unreadable is not unusable, so the entry is emitted anyway.
if [[ "$got43" == "$A:$noperm" && $rc -eq 0 ]] \
	&& grep -q "'$noperm' is not readable (emitted anyway)" "$WORK/err43"; then
	ok "permission-denied directory is emitted with a warning (exit 0)"
else
	bad "chmod 000 emit" "got: $got43 / rc=$rc / err: $(cat "$WORK/err43")"
fi
# Restore perms so subsequent tests / rm -rf work.
chmod 755 "$noperm"

# --- Test 44: missing all forms -> error mentions canonical XDG-default path ---
t 44 'missing all forms -> error mentions canonical XDG-default path'
home44="$WORK/home44"
mkdir -p "$home44"
env -i HOME="$home44" "$BIN" >/dev/null 2>"$WORK/err44"
rc=$?
if [[ $rc -ne 0 ]] && grep -q "$home44/.config/pathset/path" "$WORK/err44"; then
	ok "missing config error names canonical XDG-default path"
else
	bad "missing canonical err" "rc=$rc / err: $(cat "$WORK/err44")"
fi

# --- Test 45: $HOME/.config/pathset/path (XDG default) found ---
t 45 '$HOME/.config/pathset/path (XDG default) found'
home45="$WORK/home45"
mkdir -p "$home45/.config/pathset"
echo "$A" >"$home45/.config/pathset/path"
got45="$(env -i HOME="$home45" "$BIN" 2>/dev/null)"
if [[ "$got45" == "$A" ]]; then
	ok "\$HOME/.config/pathset/path (XDG default) found"
else
	bad "XDG default" "got: $got45"
fi

# --- Test 46: XDG default precedes legacy ~/.pathset/path ---
t 46 'XDG default precedes legacy ~/.pathset/path'
home46="$WORK/home46"
mkdir -p "$home46/.config/pathset" "$home46/.pathset"
echo "$A" >"$home46/.config/pathset/path"
echo "$B" >"$home46/.pathset/path"
got46="$(env -i HOME="$home46" "$BIN" 2>/dev/null)"
if [[ "$got46" == "$A" ]]; then
	ok "XDG default precedes legacy ~/.pathset/path"
else
	bad "XDG precedence over legacy" "got: $got46"
fi

# --- Test 47: -f man reads ~/.config/pathset/man ---
t 47 '-f man reads ~/.config/pathset/man'
home_man="$WORK/home_man"
mkdir -p "$home_man/.config/pathset"
echo "$A" >"$home_man/.config/pathset/man"
got_man="$(env -i HOME="$home_man" "$BIN" -f man 2>/dev/null)"
if [[ "$got_man" == "$A" ]]; then
	ok "-f man reads ~/.config/pathset/man"
else
	bad "-f man" "got: $got_man"
fi

# --- Test 48: -f info reads ~/.config/pathset/info ---
t 48 '-f info reads ~/.config/pathset/info'
home_info="$WORK/home_info"
mkdir -p "$home_info/.config/pathset"
echo "$B" >"$home_info/.config/pathset/info"
got_info="$(env -i HOME="$home_info" "$BIN" -f info 2>/dev/null)"
if [[ "$got_info" == "$B" ]]; then
	ok "-f info reads ~/.config/pathset/info"
else
	bad "-f info" "got: $got_info"
fi

# --- Test 49: -f fpath reads ~/.config/pathset/fpath ---
t 49 '-f fpath reads ~/.config/pathset/fpath'
home_fp="$WORK/home_fp"
mkdir -p "$home_fp/.config/pathset"
echo "$C" >"$home_fp/.config/pathset/fpath"
got_fp="$(env -i HOME="$home_fp" "$BIN" -f fpath 2>/dev/null)"
if [[ "$got_fp" == "$C" ]]; then
	ok "-f fpath reads ~/.config/pathset/fpath"
else
	bad "-f fpath" "got: $got_fp"
fi

# --- Test 50: -f path is equivalent to no -f ---
t 50 '-f path is equivalent to no -f'
home_p="$WORK/home_p"
mkdir -p "$home_p/.config/pathset"
echo "$A" >"$home_p/.config/pathset/path"
got_default="$(env -i HOME="$home_p" "$BIN" 2>/dev/null)"
got_fpath="$(env -i HOME="$home_p" "$BIN" -f path 2>/dev/null)"
if [[ "$got_default" == "$A" ]] && [[ "$got_default" == "$got_fpath" ]]; then
	ok "-f path equivalent to default (no -f)"
else
	bad "-f path default" "default: $got_default / -f path: $got_fpath"
fi

# --- Test 51: a bare -f argument names any config under pathset/ ---
t 51 'a bare -f argument names any config under pathset/'
home_any="$WORK/home_any"
mkdir -p "$home_any/.config/pathset"
echo "$A" >"$home_any/.config/pathset/toolchain"
got_any="$(env -i HOME="$home_any" "$BIN" -f toolchain 2>/dev/null)"
env -i HOME="$home_any" "$BIN" -f bogus >/dev/null 2>"$WORK/err_fbogus"
rc_fbogus=$?
if [[ "$got_any" == "$A" ]] && [[ $rc_fbogus -eq 1 ]] \
	&& grep -q "$home_any/.config/pathset/bogus" "$WORK/err_fbogus"; then
	ok "any name is looked up; a missing one is exit 1 naming the path tried"
else
	bad "-f arbitrary name" "got: $got_any / bogus rc=$rc_fbogus $(cat "$WORK/err_fbogus")"
fi

# --- Test 52: --file with no argument is named by its long spelling ---
t 52 '--file with no argument is named by its long spelling'
"$BIN" --file >/dev/null 2>"$WORK/err_fnoarg"
rc=$?
if [[ $rc -eq 2 ]] && grep -q -- '--file requires an argument' "$WORK/err_fnoarg"; then
	ok "--file with no arg exits 2 and reports --file, not -f"
else
	bad "--file no arg" "rc=$rc / err: $(cat "$WORK/err_fnoarg")"
fi

# --- Test 53: an -f file argument bypasses the named-config lookup ---
t 53 'an -f file argument bypasses the named-config lookup'
home_byp="$WORK/home_byp"
mkdir -p "$home_byp/.config/pathset"
echo "$B" >"$home_byp/.config/pathset/path"
cfg_byp="$WORK/cfg_byp"
echo "$A" >"$cfg_byp"
got_byp="$(env -i HOME="$home_byp" "$BIN" -f "$cfg_byp" 2>/dev/null)"
if [[ "$got_byp" == "$A" ]]; then
	ok "-f FILE is read even when a named config exists"
else
	bad "-f FILE bypass" "got: $got_byp"
fi

# --- Test 54: legacy ~/.pathset/<name> fallback works for a non-default config ---
t 54 'legacy ~/.pathset/<name> fallback works for a non-default config'
home_legacy_man="$WORK/home_legacy_man"
mkdir -p "$home_legacy_man/.pathset"
echo "$A" >"$home_legacy_man/.pathset/man"
got_legacy_man="$(env -i HOME="$home_legacy_man" "$BIN" -f man 2>/dev/null)"
if [[ "$got_legacy_man" == "$A" ]]; then
	ok "legacy ~/.pathset/<name> works for a non-default config"
else
	bad "legacy man" "got: $got_legacy_man"
fi

# --- Test 55: set-but-empty $VAR is skipped, not expanded to nothing ---
t 55 'set-but-empty $VAR is skipped, not expanded to nothing'
cfg_ev="$WORK/cfg_ev"
printf '%s\n$MTVAR/usr/bin\n' "$A" >"$cfg_ev"
got_ev="$(MTVAR="" "$BIN" -f "$cfg_ev" 2>"$WORK/err_ev")"
rc_ev=$?
if [[ "$got_ev" == "$A" && $rc_ev -eq 3 ]] && grep -q 'MTVAR is empty' "$WORK/err_ev"; then
	ok "set-but-empty \$VAR is skipped, not expanded to ''"
else
	bad "empty \$VAR" "rc=$rc_ev got: $got_ev stderr: $(cat "$WORK/err_ev")"
fi

# --- Test 56: ?conditional with set-but-empty $VAR is silent (exit 0) ---
t 56 '?conditional with set-but-empty $VAR is silent (exit 0)'
cfg_oev="$WORK/cfg_oev"
printf '%s\n?$MTVAR/usr/bin\n' "$A" >"$cfg_oev"
got_oev="$(MTVAR="" "$BIN" -f "$cfg_oev" 2>"$WORK/err_oev")"
rc_oev=$?
if [[ "$got_oev" == "$A" && $rc_oev -eq 0 && ! -s "$WORK/err_oev" ]]; then
	ok "?conditional with empty \$VAR is silent (exit 0)"
else
	bad "?conditional empty \$VAR" "rc=$rc_oev stderr: $(cat "$WORK/err_oev")"
fi

# --- Test 57: --help is accepted and exits 0 ---
t 57 '--help is accepted and exits 0'
if out_lh="$("$BIN" --help 2>"$WORK/err_lh")" && [[ "$out_lh" == Usage:* ]]; then
	ok "--help prints usage on stdout and exits 0"
else
	bad "--help" "rc=$? stderr: $(cat "$WORK/err_lh")"
fi

# --- Test 58: --version is accepted and exits 0 ---
t 58 '--version is accepted and exits 0'
if out_lv="$("$BIN" --version 2>/dev/null)" && [[ "$out_lv" =~ ^pathset\ [0-9]+\.[0-9]+ ]]; then
	ok "--version prints version and exits 0"
else
	bad "--version" "got: ${out_lv:-}"
fi

# --- Test 59: unknown long option exits 2 and names itself ---
t 59 'unknown long option exits 2 and names itself'
"$BIN" --bogus >/dev/null 2>"$WORK/err_lb"
rc_lb=$?
if [[ $rc_lb -eq 2 ]] && grep -q -- '--bogus' "$WORK/err_lb"; then
	ok "unknown long option exits 2 and names the option"
else
	bad "--bogus" "rc=$rc_lb stderr: $(cat "$WORK/err_lb")"
fi

# --- Test 60: dedup treats a trailing slash as the same directory ---
t 60 'dedup treats a trailing slash as the same directory'
cfg_ts="$WORK/cfg_ts"
printf '%s\n%s/\n' "$A" "$A" >"$cfg_ts"
got_ts="$("$BIN" -f "$cfg_ts" 2>/dev/null)"
if [[ "$got_ts" == "$A" ]]; then
	ok "dedup collapses '/x' and '/x/', keeping the first as declared"
else
	bad "dedup trailing slash" "got: $got_ts"
fi

# --- Test 61: the surviving entry keeps the form it was declared in ---
t 61 'the surviving entry keeps the form it was declared in'
cfg_ts2="$WORK/cfg_ts2"
printf '%s/\n%s\n' "$A" "$A" >"$cfg_ts2"
got_ts2="$("$BIN" -f "$cfg_ts2" 2>/dev/null)"
if [[ "$got_ts2" == "$A/" ]]; then
	ok "dedup emits the first occurrence verbatim, slash and all"
else
	bad "dedup trailing slash form" "got: $got_ts2"
fi

# --- Test 62: dedup runs after expansion, so ~ and $HOME collapse ---
t 62 'dedup runs after expansion, so ~ and $HOME collapse'
homedd="$WORK/home-dedup"
mkdir -p "$homedd/bin"
: >"$homedd/bin/file"
cfg_ts3="$WORK/cfg_ts3"
printf '~/bin\n$HOME/bin\n' >"$cfg_ts3"
got_ts3="$(HOME="$homedd" "$BIN" -f "$cfg_ts3" 2>/dev/null)"
if [[ "$got_ts3" == "$homedd/bin" ]]; then
	ok "'~/bin' and '\$HOME/bin' collapse to one entry"
else
	bad "dedup after expansion" "got: $got_ts3"
fi

# --- Test 63: dedup does not merge distinct dirs sharing a prefix ---
t 63 'dedup does not merge distinct dirs sharing a prefix'
mkdir -p "${A}x" && : >"${A}x/file"
cfg_ts4="$WORK/cfg_ts4"
printf '%s\n%sx\n' "$A" "$A" >"$cfg_ts4"
got_ts4="$("$BIN" -f "$cfg_ts4" 2>/dev/null)"
if [[ "$got_ts4" == "$A:${A}x" ]]; then
	ok "dedup does not merge '/x' and '/xy'"
else
	bad "dedup prefix collision" "got: $got_ts4"
fi

# --- Test 64: -q on a clean config stays completely silent ---
t 64 '-q on a clean config stays completely silent'
"$BIN" -f "$cfg1" -q >/dev/null 2>"$WORK/err_qc"
if [[ ! -s "$WORK/err_qc" ]]; then
	ok "-q on a clean config prints nothing at all"
else
	bad "-q clean" "err: $(cat "$WORK/err_qc")"
fi

# --- Test 65: without -q the summary is not added on top of the warnings ---
t 65 'without -q the summary is not added on top of the warnings'
"$BIN" -f "$cfg9" >/dev/null 2>"$WORK/err_nq"
if grep -q 'emitted anyway' "$WORK/err_nq" && ! grep -q 'omit -q to see which' "$WORK/err_nq"; then
	ok "without -q the per-entry warning stands alone (no duplicate summary)"
else
	bad "no -q summary" "err: $(cat "$WORK/err_nq")"
fi

# --- Test 66: summary is pluralised on more than one skip ---
t 66 'summary is pluralised on more than one skip'
cfg_pl="$WORK/cfg_pl"
unset PATHSET_PL_1 PATHSET_PL_2
printf '%s\n$PATHSET_PL_1/x\n$PATHSET_PL_2/y\n' "$A" >"$cfg_pl"
"$BIN" -f "$cfg_pl" -q >/dev/null 2>"$WORK/err_pl"
if grep -q '2 entries skipped' "$WORK/err_pl"; then
	ok "skip summary pluralises correctly"
else
	bad "summary plural" "err: $(cat "$WORK/err_pl")"
fi

# --- Test 67: every entry skipped -> exit 3, nothing on stdout ---
t 67 'every entry skipped -> exit 3, nothing on stdout'
cfg_ae="$WORK/cfg_ae"
unset PATHSET_AE_1 PATHSET_AE_2
printf '$PATHSET_AE_1/nope1\n$PATHSET_AE_2/nope2\n' >"$cfg_ae"
got_ae="$("$BIN" -f "$cfg_ae" -q 2>"$WORK/err_ae")"
rc_ae=$?
if [[ -z "$got_ae" && $rc_ae -eq 3 ]] && grep -q -- '--allow-empty' "$WORK/err_ae"; then
	ok "skips that empty the result exit 3, not 1, and still refuse stdout"
else
	bad "all skipped" "rc=$rc_ae got: $got_ae err: $(cat "$WORK/err_ae")"
fi

# --- Test 68: --allow-empty permits it, exit 3 still reports the skips ---
t 68 '--allow-empty permits it, exit 3 still reports the skips'
got_ae2="$("$BIN" -f "$cfg_ae" -q --allow-empty 2>/dev/null)"
rc_ae2=$?
if [[ -z "$got_ae2" && $rc_ae2 -eq 3 ]]; then
	ok "--allow-empty permits an empty result, exit 3 still reports skips"
else
	bad "--allow-empty" "rc=$rc_ae2 got: $got_ae2"
fi

# --- Test 69: --allow-empty on a genuinely empty config exits 0 ---
t 69 '--allow-empty on a genuinely empty config exits 0'
"$BIN" -f "$cfg2" --allow-empty >/dev/null 2>"$WORK/err_ae3"
rc_ae3=$?
if [[ $rc_ae3 -eq 0 && ! -s "$WORK/err_ae3" ]]; then
	ok "--allow-empty on an empty config exits 0"
else
	bad "--allow-empty empty cfg" "rc=$rc_ae3 err: $(cat "$WORK/err_ae3")"
fi

# --- Test 70: --check validates without printing to stdout ---
t 70 '--check validates without printing to stdout'
got_ck="$("$BIN" -f "$cfg1" --check 2>/dev/null)"
rc_ck=$?
if [[ -z "$got_ck" && $rc_ck -eq 0 ]]; then
	ok "--check prints nothing on stdout and exits 0 on a clean config"
else
	bad "--check clean" "rc=$rc_ck got: $got_ck"
fi

# --- Test 71: --check reports a rotted config with exit 3, still no stdout ---
t 71 '--check reports a rotted config with exit 3, still no stdout'
cfg_rot="$WORK/cfg_rot"
unset PATHSET_ROT_UNSET
printf '%s\n$PATHSET_ROT_UNSET/bin\n' "$A" >"$cfg_rot"
got_ck2="$("$BIN" -f "$cfg_rot" --check 2>"$WORK/err_ck2")"
rc_ck2=$?
if [[ -z "$got_ck2" && $rc_ck2 -eq 3 ]] && grep -q 'skipping' "$WORK/err_ck2"; then
	ok "--check exits 3 on a rotted config and prints nothing on stdout"
else
	bad "--check rotted" "rc=$rc_ck2 got: $got_ck2"
fi

# --- Test 72: --check on a missing config is still fatal ---
t 72 '--check on a missing config is still fatal'
"$BIN" -f "$WORK/does-not-exist" --check >/dev/null 2>/dev/null
rc_ck3=$?
if [[ $rc_ck3 -eq 1 ]]; then
	ok "--check on a missing config still exits 1"
else
	bad "--check missing" "rc=$rc_ck3"
fi

# --- Test 73: an entry containing ':' is unrepresentable and is skipped ---
t 73 'an entry containing '\'':'\'' is unrepresentable and is skipped'
mkdir -p "$WORK/co:lon" && : >"$WORK/co:lon/file"
cfg_co="$WORK/cfg_co"
printf '%s\n%s/co:lon\n' "$A" "$WORK" >"$cfg_co"
got_co="$("$BIN" -f "$cfg_co" 2>"$WORK/err_co")"
rc_co=$?
if [[ "$got_co" == "$A" && $rc_co -eq 3 ]] && grep -q "':'" "$WORK/err_co"; then
	ok "entry containing ':' is skipped, not emitted as two entries"
else
	bad "colon entry" "rc=$rc_co got: $got_co err: $(cat "$WORK/err_co")"
fi

# --- Test 74: ?conditional colon entry is silently skipped (exit 0) ---
t 74 '?conditional colon entry is silently skipped (exit 0)'
cfg_co2="$WORK/cfg_co2"
printf '%s\n?%s/co:lon\n' "$A" "$WORK" >"$cfg_co2"
got_co2="$("$BIN" -f "$cfg_co2" 2>"$WORK/err_co2")"
rc_co2=$?
if [[ "$got_co2" == "$A" && $rc_co2 -eq 0 && ! -s "$WORK/err_co2" ]]; then
	ok "?conditional entry containing ':' is silently skipped"
else
	bad "conditional colon entry" "rc=$rc_co2 got: $got_co2 err: $(cat "$WORK/err_co2")"
fi

# --- Test 75: a colon arriving via expansion is caught too ---
t 75 'a colon arriving via expansion is caught too'
cfg_co3="$WORK/cfg_co3"
printf '%s\n$COLONVAR\n' "$A" >"$cfg_co3"
got_co3="$(COLONVAR="$WORK/co:lon" "$BIN" -f "$cfg_co3" 2>/dev/null)"
rc_co3=$?
if [[ "$got_co3" == "$A" && $rc_co3 -eq 3 ]]; then
	ok "a ':' introduced by \$VAR expansion is caught after expanding"
else
	bad "expanded colon" "rc=$rc_co3 got: $got_co3"
fi

# --- Test 76: ?conditional on an empty directory is dropped silently ---
t 76 '?conditional on an empty directory is dropped silently'
cfg76="$WORK/cfg76"
printf '%s\n?%s\n' "$A" "$empty" >"$cfg76"
got76="$("$BIN" -f "$cfg76" 2>"$WORK/err76")"
rc76=$?
if [[ "$got76" == "$A" && $rc76 -eq 0 && ! -s "$WORK/err76" ]]; then
	ok "?conditional empty directory is dropped silently (exit 0)"
else
	bad "?conditional empty dir" "rc=$rc76 got: $got76 err: $(cat "$WORK/err76")"
fi

# --- Test 77: execute-but-not-read directory is emitted with a warning ---
t 77 'execute-but-not-read directory is emitted with a warning'
xonly="$WORK/xonly"
mkdir -p "$xonly"
: >"$xonly/file"
chmod 0111 "$xonly"
# Widen the cleanup trap: rm -rf cannot descend into a 0111 directory either.
trap 'chmod 755 "$noperm" "$xonly" 2>/dev/null; rm -rf "$WORK"' EXIT
cfg77="$WORK/cfg77"
printf '%s\n%s\n' "$A" "$xonly" >"$cfg77"
got77="$("$BIN" -f "$cfg77" 2>"$WORK/err77")"
rc77=$?
if [[ "$got77" == "$A:$xonly" && $rc77 -eq 0 ]] \
	&& grep -q "'$xonly' is not readable (emitted anyway)" "$WORK/err77"; then
	ok "0111 directory is emitted: PATH lookup needs x, not r"
else
	bad "exec-only dir" "rc=$rc77 got: $got77 err: $(cat "$WORK/err77")"
fi

# --- Test 78: ?conditional on an execute-only directory is dropped ---
t 78 '?conditional on an execute-only directory is dropped'
cfg78="$WORK/cfg78"
printf '%s\n?%s\n' "$A" "$xonly" >"$cfg78"
got78="$("$BIN" -f "$cfg78" 2>"$WORK/err78")"
rc78=$?
if [[ "$got78" == "$A" && $rc78 -eq 0 && ! -s "$WORK/err78" ]]; then
	ok "?conditional execute-only directory is dropped silently"
else
	bad "?conditional exec-only" "rc=$rc78 got: $got78 err: $(cat "$WORK/err78")"
fi
chmod 755 "$xonly"

# --- Test 79: summary pluralises entries emitted with warnings ---
t 79 'summary pluralises entries emitted with warnings'
cfg79="$WORK/cfg79"
printf '%s\n%s/nope1\n%s/nope2\n' "$A" "$WORK" "$WORK" >"$cfg79"
"$BIN" -f "$cfg79" -q >/dev/null 2>"$WORK/err79"
if grep -q '2 entries emitted with warnings' "$WORK/err79"; then
	ok "warning summary pluralises correctly"
else
	bad "warning summary plural" "err: $(cat "$WORK/err79")"
fi

# --- Test 80: the -q summary reports warnings and skips together ---
t 80 'the -q summary reports warnings and skips together'
cfg80="$WORK/cfg80"
unset PATHSET_SUM_UNSET
printf '%s\n%s/nope\n$PATHSET_SUM_UNSET/bin\n' "$A" "$WORK" >"$cfg80"
"$BIN" -f "$cfg80" -q >/dev/null 2>"$WORK/err80"
rc80=$?
if [[ $rc80 -eq 3 ]] \
	&& grep -q '1 entry emitted with a warning, 1 entry skipped' "$WORK/err80"; then
	ok "-q summary carries both counts; only the skip reaches the exit code"
else
	bad "combined summary" "rc=$rc80 err: $(cat "$WORK/err80")"
fi

# --- Test 81: an empty result that no skip explains stays exit 1 ---
t 81 'an empty result that no skip explains stays exit 1'
cfg81="$WORK/cfg81"
printf '# just a comment\n\n' >"$cfg81"
got81="$("$BIN" -f "$cfg81" 2>"$WORK/err81")"
rc81=$?
if [[ -z "$got81" && $rc81 -eq 1 ]] && grep -q -- '--allow-empty' "$WORK/err81"; then
	ok "a comment-only config is exit 1, not 3"
else
	bad "comment-only cfg" "rc=$rc81 got: $got81 err: $(cat "$WORK/err81")"
fi

# --- Test 82: --check does not suppress the empty guard ---
t 82 '--check does not suppress the empty guard'
"$BIN" -f "$cfg_ae" --check >/dev/null 2>"$WORK/err82"
rc82=$?
if [[ $rc82 -eq 3 ]] && grep -q 'refusing to print an empty result' "$WORK/err82"; then
	ok "--check on an all-skipped config still refuses, exit 3"
else
	bad "--check empty guard" "rc=$rc82 err: $(cat "$WORK/err82")"
fi

# --- Test 83: an abbreviated long option is rejected ---
t 83 'an abbreviated long option is rejected'
"$BIN" --che -f "$cfg1" >/dev/null 2>"$WORK/err_abbr"
rc_abbr=$?
if [[ $rc_abbr -eq 2 ]] && grep -q 'unknown argument: --che$' "$WORK/err_abbr"; then
	ok "an abbreviated long option is rejected and echoed as written"
else
	bad "--che" "rc=$rc_abbr err: $(cat "$WORK/err_abbr")"
fi

# --- Test 84: a long option given an argument it does not take is rejected ---
t 84 'a long option given an argument it does not take is rejected'
"$BIN" --check=1 -f "$cfg1" >/dev/null 2>"$WORK/err_leq"
rc_leq=$?
if [[ $rc_leq -eq 2 ]] && grep -q -- 'unknown argument: --check=1$' "$WORK/err_leq"; then
	ok "--check=value is rejected; --check takes no argument"
else
	bad "--check=1" "rc=$rc_leq err: $(cat "$WORK/err_leq")"
fi

# --- Test 85: '--' ends option scanning ---
t 85 "'--' ends option scanning"
"$BIN" -f "$cfg1" -- --check >/dev/null 2>"$WORK/err_dd"
rc_dd=$?
if [[ $rc_dd -eq 2 ]] && grep -q -- 'unexpected argument: --check$' "$WORK/err_dd"; then
	ok "'--' ends option scanning; what follows is a positional, and fatal"
else
	bad "-- ends options" "rc=$rc_dd err: $(cat "$WORK/err_dd")"
fi

# --- Test 86: argv is read left to right, so an earlier error wins ---
t 86 'argv is read left to right, so an earlier error wins'
"$BIN" -Z --help >/dev/null 2>"$WORK/err_ltr"
rc_ltr=$?
if [[ $rc_ltr -eq 2 ]] && grep -q 'unknown argument: -Z' "$WORK/err_ltr"; then
	ok "a bad option before --help still exits 2"
else
	bad "-Z --help" "rc=$rc_ltr err: $(cat "$WORK/err_ltr")"
fi

# --- Test 87: ... and --help wins over what follows it ---
t 87 '... and --help wins over what follows it'
out_ltr2="$("$BIN" --help --bogus 2>"$WORK/err_ltr2")"
rc_ltr2=$?
if [[ $rc_ltr2 -eq 0 && "$out_ltr2" == Usage:* && ! -s "$WORK/err_ltr2" ]]; then
	ok "--help exits before a later bad option is reached"
else
	bad "--help --bogus" "rc=$rc_ltr2 err: $(cat "$WORK/err_ltr2")"
fi

# --- Test 88: -f with a bare name selects that config ---
t 88 '-f with a bare name selects that config'
mkdir -p "$xdg/pathset"
echo "$B" >"$xdg/pathset/man"
got88="$(env -i HOME="$WORK/home" XDG_CONFIG_HOME="$xdg" "$BIN" -f man 2>/dev/null)"
if [[ "$got88" == "$B" ]]; then
	ok "-f man reads XDG_CONFIG_HOME/pathset/man"
else
	bad "-f bare name" "got: $got88"
fi

# --- Test 89: an -f argument containing '/' is a file path ---
t 89 "an -f argument containing '/' is a file path"
cfg89="$WORK/cfg89"
echo "$C" >"$cfg89"
got89="$("$BIN" -f "$cfg89" 2>/dev/null)"
if [[ "$got89" == "$C" ]]; then
	ok "-f with a slash reads that file"
else
	bad "-f file path" "got: $got89"
fi

# --- Test 90: --file is the long form of -f ---
t 90 '--file is the long form of -f'
got91="$("$BIN" --file "$cfg89" 2>/dev/null)"
if [[ "$got91" == "$C" ]]; then
	ok "--file reads the same config as -f"
else
	bad "--file long form" "got: $got91"
fi

# --- Test 91: a repeated -f is last-wins across both branches ---
t 91 'a repeated -f is last-wins across both branches'
got92a="$(env -i HOME="$WORK/home" XDG_CONFIG_HOME="$xdg" "$BIN" -f "$cfg89" -f man 2>/dev/null)"
got92b="$(env -i HOME="$WORK/home" XDG_CONFIG_HOME="$xdg" "$BIN" -f man -f "$cfg89" 2>/dev/null)"
if [[ "$got92a" == "$B" && "$got92b" == "$C" ]]; then
	ok "the last -f wins whichever branch it takes"
else
	bad "-f last wins" "file-then-name: $got92a  name-then-file: $got92b"
fi

# --- Test 92: -s joins with a space instead of ':' ---
t 92 "-s joins with a space instead of ':'"
cfg93="$WORK/cfg93"
printf '%s\n%s\n' "$A" "$B" >"$cfg93"
got93="$("$BIN" -f "$cfg93" -s 2>/dev/null)"
if [[ "$got93" == "$A $B" ]]; then
	ok "-s emits a space-joined list"
else
	bad "-s separator" "got: $got93"
fi

# --- Test 93: --space is the long form of -s ---
t 93 '--space is the long form of -s'
got94="$("$BIN" -f "$cfg93" --space 2>/dev/null)"
if [[ "$got94" == "$A $B" ]]; then
	ok "--space emits a space-joined list"
else
	bad "--space long form" "got: $got94"
fi

# --- Test 94: under -s an entry containing whitespace is unrepresentable ---
t 94 'under -s an entry containing whitespace is unrepresentable'
spacedir="$WORK/sp ace"
mkdir -p "$spacedir"
: >"$spacedir/file"
cfg95="$WORK/cfg95"
printf '%s\n%s\n' "$A" "$spacedir" >"$cfg95"
got95="$("$BIN" -f "$cfg95" -s 2>"$WORK/err95")"
rc95=$?
if [[ "$got95" == "$A" && $rc95 -eq 3 ]] && grep -q 'whitespace' "$WORK/err95"; then
	ok "-s skips a whitespace entry instead of splitting it"
else
	bad "-s whitespace entry" "rc=$rc95 got: $got95 err: $(cat "$WORK/err95")"
fi

# --- Test 95: under -s an entry containing ':' is emitted ---
t 95 "under -s an entry containing ':' is emitted"
colondir="$WORK/co:lon"
mkdir -p "$colondir"
: >"$colondir/file"
cfg96="$WORK/cfg96"
printf '%s\n%s\n' "$A" "$colondir" >"$cfg96"
got96="$("$BIN" -f "$cfg96" -s 2>/dev/null)"
rc96=$?
if [[ "$got96" == "$A $colondir" && $rc96 -eq 0 ]]; then
	ok "':' is representable in a space-joined list"
else
	bad "-s colon entry" "rc=$rc96 got: $got96"
fi

# --- Test 96: -s --check reports the drop with no stdout ---
t 96 '-s --check reports the drop with no stdout'
got97="$("$BIN" -f "$cfg95" -s --check 2>"$WORK/err97")"
rc97=$?
if [[ -z "$got97" && $rc97 -eq 3 ]] && grep -q 'whitespace' "$WORK/err97"; then
	ok "--check validates the space-joined form without printing it"
else
	bad "-s --check" "rc=$rc97 got: $got97 err: $(cat "$WORK/err97")"
fi

# --- Test 97: --file=NAME is accepted, unlike an abbreviation ---
t 97 '--file=NAME is accepted, unlike an abbreviation'
got97="$(env -i HOME="$WORK/home" XDG_CONFIG_HOME="$xdg" "$BIN" --file=man 2>"$WORK/err97b")"
rc97b=$?
"$BIN" --fil=man >/dev/null 2>"$WORK/err97c"
rc97c=$?
if [[ "$got97" == "$B" && $rc97b -eq 0 ]] && [[ $rc97c -eq 2 ]] \
	&& grep -q -- 'unknown argument: --fil=man' "$WORK/err97c"; then
	ok "only the part before '=' is the spelling; --fil=man is still rejected"
else
	bad "--file=NAME" "rc=$rc97b got: $got97 / --fil rc=$rc97c $(cat "$WORK/err97c")"
fi

# --- Test 98: --space given an argument is echoed as written ---
t 98 '--space given an argument is echoed as written'
"$BIN" --space=x >/dev/null 2>"$WORK/err98"
rc98=$?
if [[ $rc98 -eq 2 ]] && grep -q -- 'unknown argument: --space=x$' "$WORK/err98"; then
	ok "--space=x names the long option, not its short spelling"
else
	bad "--space=x" "rc=$rc98 err: $(cat "$WORK/err98")"
fi

# --- Test 99: an empty -f argument is rejected ---
t 99 'an empty -f argument is rejected'
"$BIN" --file= >/dev/null 2>"$WORK/err99a"
rc99a=$?
"$BIN" -f "" >/dev/null 2>"$WORK/err99b"
rc99b=$?
if [[ $rc99a -eq 2 && $rc99b -eq 2 ]] \
	&& grep -q 'not an empty string' "$WORK/err99a" \
	&& grep -q 'not an empty string' "$WORK/err99b"; then
	ok "an empty -f is neither a name nor a path, in both spellings"
else
	bad "-f empty" "--file= rc=$rc99a / -f '' rc=$rc99b: $(cat "$WORK/err99b")"
fi

# --- Test 101: --file NAME does not swallow the option that follows it ---
# The separate-argument form leaves optind two past the token, so a naive
# scan finds the *next* option and rejects a correctly spelled one.
t 101 '--file NAME does not swallow the option that follows it'
fail101=""
for follow in --check --allow-empty --space --version --help; do
	"$BIN" --file "$cfg1" "$follow" >/dev/null 2>"$WORK/err101"
	rc101=$?
	[[ $rc101 -eq 0 ]] || fail101="$fail101 $follow(rc=$rc101: $(cat "$WORK/err101"))"
done
if [[ -z "$fail101" ]]; then
	ok "--file NAME is fine before every long option"
else
	bad "--file NAME + long option" "$fail101"
fi

# --- Test 102: an abbreviation is rejected in the two-token form too ---
t 102 'an abbreviation is rejected in the two-token form too'
fail102=""
for abbr in --f --fi --fil; do
	"$BIN" "$abbr" "$cfg1" >/dev/null 2>"$WORK/err102"
	rc102=$?
	grep -q "unknown argument: $abbr\$" "$WORK/err102" || fail102="$fail102 $abbr(no-msg)"
	[[ $rc102 -eq 2 ]] || fail102="$fail102 $abbr(rc=$rc102)"
done
if [[ -z "$fail102" ]]; then
	ok "--f/--fi/--fil NAME are rejected and echoed as written"
else
	bad "abbreviation, two-token form" "$fail102"
fi

# --- Test 103: a failed stdout write is reported, not swallowed ---
# stdout is the whole product, and $(...) reports the shell's status, not
# ours -- so a short write has to be caught here or it is never caught.
# A closed fd 1 is the portable way to force one; ENOSPC takes the same path.
t 103 'a failed stdout write is reported, not swallowed'
"$BIN" -f "$cfg1" -q >&- 2>"$WORK/err103"
rc103=$?
"$BIN" -V >&- 2>"$WORK/err103v"
rc103v=$?
"$BIN" -f "$cfg1" --check >&- 2>"$WORK/err103c"
rc103c=$?
if [[ $rc103 -eq 1 && $rc103v -eq 1 && $rc103c -eq 0 ]] \
	&& grep -q 'write error on stdout' "$WORK/err103" \
	&& grep -q 'write error on stdout' "$WORK/err103v" \
	&& [[ ! -s "$WORK/err103c" ]]; then
	ok "a closed stdout is a fatal write error; --check writes nothing so it still succeeds"
else
	bad "stdout write error" "path rc=$rc103 -V rc=$rc103v --check rc=$rc103c: $(cat "$WORK/err103")"
fi

# --- Test 100: an argument error is a hint, not the whole help ---
t 100 'an argument error is a hint, not the whole help'
"$BIN" -z >"$WORK/out100" 2>"$WORK/err100"
rc100=$?
lines100=$(wc -l <"$WORK/err100" | tr -d ' ')
"$BIN" -h >"$WORK/h100" 2>"$WORK/herr100"
if [[ $rc100 -eq 2 && $lines100 -eq 2 && ! -s "$WORK/out100" ]] \
	&& grep -q '^pathset: unknown argument: -z$' "$WORK/err100" \
	&& grep -q "^Try 'pathset --help' for more information\.$" "$WORK/err100" \
	&& ! grep -q '^Usage:' "$WORK/err100" \
	&& [[ ! -s "$WORK/herr100" ]] && grep -q '^Usage:' "$WORK/h100"; then
	ok "an error prints 2 stderr lines and points at -h; -h still prints the help on stdout"
else
	bad "usage hint" "rc=$rc100 stderr lines=$lines100: $(cat "$WORK/err100")"
fi

# --- Summary ---
echo
if [[ $LIST -eq 1 ]]; then
	echo "$total tests"
	exit 0
fi
echo "passed: $pass  failed: $fail"
if [[ -n "$FILTER" ]]; then
	echo "NOT A FULL RUN: filter '$FILTER' selected $selected of $total tests"
	if [[ $selected -eq 0 ]]; then
		echo "tests: filter '$FILTER' matched nothing" >&2
		exit 2
	fi
fi
[[ $fail -eq 0 ]] || exit 1
