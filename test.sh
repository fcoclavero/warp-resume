#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Regression suite for warp-resume.
#
#   bash test.sh
#
# Runs in a throwaway HOME/ZDOTDIR with stubbed `claude` and `codex`.
# Touches nothing in your real home. Run it after ANY edit.
#
# Several of these guard against bugs that were live at some point and are not
# obvious from reading the code -- read the comment on a test before "fixing" it.
# ---------------------------------------------------------------------------

set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SRC/record-session.sh"
ZSHLIB="$SRC/warp-resume.zsh"

command -v zsh >/dev/null 2>&1 || { echo "zsh not found"; exit 1; }
python3 -c 'import json' >/dev/null 2>&1 || { echo "working python3 required for test fixtures"; exit 1; }
for f in "$HOOK" "$ZSHLIB"; do [ -f "$f" ] || { echo "missing: $f"; exit 1; }; done

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
# Isolate interactive zsh from the user's real ~/.zshrc: it can re-order PATH
# (shadowing the stubbed claude below with the real one) or even source
# warp-resume.zsh itself. Empty rc file so zsh-newuser-install stays quiet.
export ZDOTDIR="$T/zdot"; mkdir -p "$ZDOTDIR"; : > "$ZDOTDIR/.zshrc"
# And scrub the product's own guard vars: running the suite from inside a
# resumed claude session inherits WARP_RESUME_ACTIVE=1, which (correctly)
# makes every reattach a silent no-op.
for var in ${!WARP_RESUME_@}; do unset "$var"; done
unset WARP_TERMINAL_SESSION_UUID CLAUDE_CONFIG_DIR CODEX_HOME SSH_CONNECTION SSH_TTY STUB_EXIT
# macOS Terminal.app: /etc/zshrc sources /etc/zshrc_Apple_Terminal (ZDOTDIR
# does not stop that), which prints "Restored session: ..." on start and
# "Saving session..." on exit of every interactive zsh -- breaking every
# "prints nothing" check. SHELL_SESSIONS_DISABLE is Apple's off switch;
# dropping TERM_PROGRAM keeps that file from loading at all.
export SHELL_SESSIONS_DISABLE=1
unset TERM_PROGRAM TERM_SESSION_ID
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/claude" <<'EOF'
#!/bin/sh
case "${0##*/}" in claude) label=CLAUDE ;; codex) label=CODEX ;; esac
printf '%s argc=%s : %s\n' "$label" "$#" "$*"
for arg do printf '%s arg=<%s>\n' "$label" "$arg"; done
printf '%s cwd=%s\n' "$label" "$PWD"
printf '%s active=%s\n' "$label" "${WARP_RESUME_ACTIVE:-}"
exit "${STUB_EXIT:-0}"
EOF
chmod +x "$BIN/claude"
cp "$BIN/claude" "$BIN/codex"
export PATH="$BIN:$PATH"

PANE1=00000000000000000000000000000001
PANE2=00000000000000000000000000000002
PANE3=00000000000000000000000000000003
PANE4=00000000000000000000000000000004
PANE5=00000000000000000000000000000005
CODEX1=00000001-0000-4000-8000-000000000001
CODEX2=00000002-0000-4000-8000-000000000002

pass=0; fail=0; skip=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
no()   { fail=$((fail+1)); printf '  FAIL  %s\n         want: %s\n         got : %s\n' "$1" "$2" "$3"; }
sk()   { skip=$((skip+1)); printf '  skip  %s (%s)\n' "$1" "$2"; }
is()   { [ "$2" = "$3" ] && ok "$1" || no "$1" "$3" "$2"; }
has()  { case "$2" in *"$3"*) ok "$1";; *) no "$1" "contains: $3" "$2";; esac; }
hasnt(){ case "$2" in *"$3"*) no "$1" "must NOT contain: $3" "$2";; *) ok "$1";; esac; }

# run the hook with a given pane uuid and JSON payload
hook() { WARP_TERMINAL_SESSION_UUID="$1" WARP_RESUME_STATE_DIR="$STATE" HOME="$FHOME" \
         "$HOOK" "${3:-claude-code}" <<EOF
$2
EOF
}
# start an interactive-ish zsh with the lib sourced; $1 = pane, rest = extra setup
zrun() {
  local pane="$1"; shift
  zsh -ic "export WARP_RESUME_STATE_DIR='$STATE'
export WARP_TERMINAL_SESSION_UUID='$pane'
$*
source '$ZSHLIB'
_warp_resume_reattach" </dev/null 2>&1
}
record() {
  local pane="$1"; shift
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-}" > "$STATE/$pane"
}
reject_hook() {
  local title="$1" payload="$2" harness="${3:-claude-code}" o before mode
  for mode in native fallback; do
    record "$PANE5" claude-code preserved-binding "$PROJ" "$NOW"
    before=$(cat "$STATE/$PANE5")
    if [ "$mode" = fallback ]; then
      o=$(PATH="$NOPY:$PATH" hook "$PANE5" "$payload" "$harness" 2>&1)
    else
      o=$(hook "$PANE5" "$payload" "$harness" 2>&1)
    fi
    is "$mode: $title is silent" "$o" ""
    is "$mode: $title preserves the existing binding" "$(cat "$STATE/$PANE5")" "$before"
  done
}
silent_record() {
  local title="$1"; shift
  record "$PANE5" "$@"
  is "$title" "$(zrun "$PANE5" 'WARP_RESUME_AUTO=1')" ""
}

STATE="$T/panes"; FHOME="$T/home"; mkdir -p "$FHOME" "$T/empty"
PROJ="$FHOME/proj"; mkdir -p "$PROJ"

echo "warp-resume regression suite"
echo "  zsh $(zsh --version | awk '{print $2}')  |  $(uname -s)"
echo

# ---------------------------------------------------------------- syntax
echo "syntax"
sh -n "$HOOK" && ok "record-session.sh parses"  || no "record-session.sh parses" ok error
zsh -n "$ZSHLIB" && ok "warp-resume.zsh parses" || no "warp-resume.zsh parses" ok error
out=$(zsh -c "emulate sh; source '$ZSHLIB'; print PARSED" 2>&1)
is "parses under 'emulate sh'" "$out" "PARSED"

# ------------------------------------------------------------- recording
echo; echo "recording"
hook "$PANE1" "{\"session_id\":\"sess-0001\",\"cwd\":\"$PROJ\"}"
hook "$PANE2" "{\"session_id\":\"sess-0002\",\"cwd\":\"$PROJ\"}"
[ -f "$STATE/$PANE1" ] && ok "record written" || no "record written" exists missing
is "record has 5 tab-separated fields" \
   "$(awk -F'\t' '{print NF}' "$STATE/$PANE1")" "5"
is "state dir is 0700" "$(ls -ld "$STATE" | cut -c2-10)" "rwx------"

# ------------------------------------------------- THE core requirement
echo; echo "core: per-pane identity"
o1=$(zrun "$PANE1" "WARP_RESUME_AUTO=1")
o2=$(zrun "$PANE2" "WARP_RESUME_AUTO=1")
has "pane 1 resumes its own session" "$o1" "--resume sess-0001"
has "pane 2 resumes its own session" "$o2" "--resume sess-0002"
hasnt "pane 1 does not get pane 2's session" "$o1" "sess-0002"

o=$(zrun "$PANE3" "WARP_RESUME_AUTO=1")
is "unknown pane does nothing" "$o" ""

o=$(zsh -ic "export WARP_RESUME_STATE_DIR='$STATE'; unset WARP_TERMINAL_SESSION_UUID
WARP_RESUME_AUTO=1; source '$ZSHLIB'; _warp_resume_reattach" </dev/null 2>&1)
is "non-Warp shell does nothing" "$o" ""

o=$(zsh -c "export WARP_RESUME_STATE_DIR='$STATE'
export WARP_TERMINAL_SESSION_UUID='$PANE1'; source '$ZSHLIB'" 2>&1)
is "non-interactive shell is silent" "$o" ""

# ------------------------------------------------------------ resume flags
echo; echo "resume flags"
o=$(zrun "$PANE1" "WARP_RESUME_CLAUDE_FLAGS=(--permission-mode bypassPermissions); WARP_RESUME_AUTO=1")
has "flags are passed" "$o" "--permission-mode bypassPermissions --resume sess-0001"
o=$(zrun "$PANE1" "WARP_RESUME_AUTO=1")
hasnt "no flags by default" "$o" "--permission-mode"
o=$(zrun "$PANE1" "WARP_RESUME_CLAUDE_FLAGS='--permission-mode bypassPermissions'; WARP_RESUME_AUTO=1")
has "scalar flags warn, not silently dropped" "$o" "must be an array"

# ------------------------------------------------------------- SECURITY
echo; echo "security"

# 1. The non-TTY path stays inert; real prompt rendering is tested in a PTY.
mkdir -p "$T/\$(touch $T/CANARY)x"
printf 'claude-code\tsidz\t%s\t%s\t\n' "$T/\$(touch $T/CANARY)x" "$(date +%s)" > "$STATE/$PANE3"
zsh -ic "setopt prompt_subst; export WARP_RESUME_STATE_DIR='$STATE'
export WARP_TERMINAL_SESSION_UUID='$PANE3'; source '$ZSHLIB'; _warp_resume_reattach" \
  </dev/null >/dev/null 2>&1
[ -f "$T/CANARY" ] && no "no command execution via cwd + PROMPT_SUBST" "no canary" "CANARY CREATED" \
                   || ok "no command execution via cwd + PROMPT_SUBST"
rm -f "$STATE/$PANE3"

# 2. flag injection through the session id
hook "$PANE3" '{"session_id":"--dangerously-skip-permissions","cwd":"/tmp"}'
[ -f "$STATE/$PANE3" ] && no "flag-shaped session id rejected" rejected written \
                       || ok "flag-shaped session id rejected"

# 3. path traversal through the pane uuid
hook "../../etc/evil" '{"session_id":"s","cwd":"/tmp"}'
[ -f "$T/etc/evil" ] && no "path traversal via pane uuid rejected" rejected written \
                     || ok "path traversal via pane uuid rejected"

# 4. record-splitting and terminal escapes through cwd
hook "$PANE3" '{"session_id":"s1","cwd":"/tmp/a\t9999999999\tbypassPermissions"}'
[ -f "$STATE/$PANE3" ] && no "tab in cwd rejected" rejected written || ok "tab in cwd rejected"
hook "$PANE3" '{"session_id":"s1","cwd":"relative/path"}'
[ -f "$STATE/$PANE3" ] && no "relative cwd rejected" rejected written || ok "relative cwd rejected"
hook "$PANE3" '{"session_id":null,"cwd":"/tmp"}'
[ -f "$STATE/$PANE3" ] && no "JSON null session id rejected" rejected written || ok "JSON null session id rejected"

# 5. a corrupt timestamp must not spew shell errors on every startup
printf 'claude-code\tsid-x\t%s\tnot-a-number\t\n' "$PROJ" > "$STATE/$PANE3"
o=$(zrun "$PANE3" "WARP_RESUME_AUTO=1")
is "corrupt timestamp is silent" "$o" ""
rm -f "$STATE/$PANE3"

# ------------------------------------------------- SECURITY, zsh side
echo; echo "security: zsh side (record is untrusted here too)"

# a. an alias on `claude` defined before the source line must not be baked in
o=$(zrun "$PANE1" "alias claude='claude --dangerously-skip-permissions'; WARP_RESUME_AUTO=1")
has   "claude alias is bypassed (binary resolved)" "$o" "--resume sess-0001"
hasnt "claude alias cannot smuggle flags" "$o" "dangerously"

# a2. Claude Code's local installer defines claude ONLY as an alias to an
#     absolute path. That shape must work; an alias with flags must not.
o=$(zrun "$PANE1" "export PATH='$T/empty'; alias claude='$BIN/claude'; WARP_RESUME_AUTO=1")
has   "alias-only install (bare absolute path) resumes" "$o" "--resume sess-0001"
o=$(zrun "$PANE1" "export PATH='$T/empty'; alias claude='$BIN/claude --dangerously-skip-permissions'; WARP_RESUME_AUTO=1")
hasnt "alias-only install with flags is refused, not honoured" "$o" "dangerously"
o=$(zrun "$PANE1" "hash claude=/nonexistent/claude; WARP_RESUME_AUTO=1")
hasnt "stale hash entry fails silently" "$o" "no such file"

# b. a cd alias/function (zoxide etc.) must not intercept the directory change
o=$(zrun "$PANE1" "alias cd='cd /'; WARP_RESUME_AUTO=1")
has "cd alias is bypassed (builtin cd)" "$o" "CLAUDE cwd=$PROJ"

# c. `.` in PATH + a record pointing at a directory that contains its own
#    `claude`: the binary must be resolved BEFORE the cd
EVIL="$T/evil"; mkdir -p "$EVIL"
printf '#!/bin/sh\necho ATTACKER-CLAUDE-RAN\n' > "$EVIL/claude"; chmod +x "$EVIL/claude"
printf 'claude-code\tsid-e\t%s\t%s\t\n' "$EVIL" "$(date +%s)" > "$STATE/$PANE3"
o=$(zrun "$PANE3" "export PATH=\".:\$PATH\"; WARP_RESUME_AUTO=1")
hasnt "record dir cannot supply the claude binary" "$o" "ATTACKER"
has   "…the PATH claude runs instead" "$o" "CLAUDE argc"
rm -f "$STATE/$PANE3"

# d. record fields the zsh side must reject even though the hook would never write them
printf 'claude-code\t--dangerously-skip-permissions\t%s\t%s\t\n' "$PROJ" "$(date +%s)" > "$STATE/$PANE3"
o=$(zrun "$PANE3" "WARP_RESUME_AUTO=1")
is "zsh side rejects flag-shaped sid" "$o" ""
printf 'claude-code\tsid;touch %s/CANARY2\t%s\t%s\t\n' "$T" "$PROJ" "$(date +%s)" > "$STATE/$PANE3"
o=$(zrun "$PANE3" "WARP_RESUME_AUTO=1")
is "zsh side rejects metacharacters in sid" "$o" ""
[ -f "$T/CANARY2" ] && no "sid metacharacters not executed" "no canary" "CANARY2 CREATED" || ok "sid metacharacters not executed"
printf 'claude-code\tsid-c\t%s\t%s\t\n' "$PROJ/"$'\e'"]0;PWNED"$'\a' "$(date +%s)" > "$STATE/$PANE3"
o=$(zrun "$PANE3" "WARP_RESUME_AUTO=1")
is "zsh side rejects control chars in cwd" "$o" ""
printf 'claude-code\tsid-t\t%s\t%s\t\n' "$PROJ" "9999999999999999999999999999999999999999" > "$STATE/$PANE3"
o=$(zrun "$PANE3" "WARP_RESUME_AUTO=1")
is "oversize timestamp is silent (no arithmetic warning)" "$o" ""
printf 'claude-code\tsid-u\t%s\t%s\t\n' "$PROJ" "$(date +%s)" > "$STATE/$PANE3"; chmod 000 "$STATE/$PANE3"
o=$(zrun "$PANE3" "WARP_RESUME_AUTO=1")
if [ "$(id -u)" = 0 ]; then sk "unreadable record is silent" "running as root"; else is "unreadable record is silent" "$o" ""; fi
chmod 600 "$STATE/$PANE3"; rm -f "$STATE/$PANE3"

# e. warp-resume-list must not put raw escapes on the terminal
printf 'claude-code\tsid-l\t%s\t%s\t\n' "$PROJ/"$'\e'"[2J" "$(date +%s)" > "$STATE/$PANE3"
n=$(zsh -ic "export WARP_RESUME_STATE_DIR='$STATE'
export WARP_TERMINAL_SESSION_UUID='$PANE3'; source '$ZSHLIB'; warp-resume-list" </dev/null 2>&1 | grep -c $'\e')
is "warp-resume-list escapes control chars" "$n" "0"
rm -f "$STATE/$PANE3"

# f. sourcing under GLOB_SUBST with a glob char in the state path
out=$(zsh -c "setopt glob_subst; WARP_RESUME_STATE_DIR='$T/a[b]'; source '$ZSHLIB'; print PARSED" 2>&1)
is "parses under GLOB_SUBST with [ in state path" "$out" "PARSED"

# g. the fallback (python3 absent/broken) must parse the real key, not a
#    forged one embedded in cwd, and must never eval
NOPY="$T/nopy"; mkdir -p "$NOPY"; printf '#!/bin/sh\nexit 1\n' > "$NOPY/python3"; chmod +x "$NOPY/python3"
PATH="$NOPY:$PATH" hook "$PANE3" "{\"session_id\":\"real-sid\",\"cwd\":\"$PROJ/x\\\\\"session_id\\\\\":\\\\\"--evil\\\\\"\"}"
[ -f "$STATE/$PANE3" ] && is "fallback takes the real session_id" "$(cut -f2 "$STATE/$PANE3")" "real-sid" \
                       || ok "fallback: forged record refused entirely"
rm -f "$STATE/$PANE3"
PATH="$NOPY:$PATH" hook "$PANE3" "{\"session_id\":\"fb-ok\",\"cwd\":\"$PROJ\"}"
is "fallback writes a normal record" "$(cut -f2 "$STATE/$PANE3" 2>/dev/null)" "fb-ok"
rm -f "$STATE/$PANE3"
# Unsupported nested payloads may be refused; a nested key must never win.
PATH="$NOPY:$PATH" hook "$PANE3" "{\"session_id\":\"first\",\"meta\":{\"session_id\":\"--evil\"},\"cwd\":\"$PROJ\"}"
[ -f "$STATE/$PANE3" ] && is "fallback never selects the nested session ID" "$(cut -f2 "$STATE/$PANE3")" "first" \
  || ok "fallback refuses unsupported nested input"
rm -f "$STATE/$PANE3"

# h. the hook must never delete anything. A prune used to live here; this
#    pins its absence: an old, non-record file in the state dir survives a run.
touch -t 200001010000 "$STATE/keep-me.txt" "$STATE/0ldhexname"
hook "$PANE1" "{\"session_id\":\"sess-0001\",\"cwd\":\"$PROJ\"}"
{ [ -f "$STATE/keep-me.txt" ] && [ -f "$STATE/0ldhexname" ]; } && ok "hook deletes nothing in the state dir" \
  || no "hook deletes nothing in the state dir" "both files kept" "something was deleted"
rm -f "$STATE/keep-me.txt" "$STATE/0ldhexname"

# ------------------------------------------------------------- robustness
echo; echo "robustness"
for opt in nounset ksh_arrays sh_word_split extended_glob warn_create_global; do
  o=$(zrun "$PANE1" "setopt $opt; WARP_RESUME_CLAUDE_FLAGS=(--permission-mode bypassPermissions); WARP_RESUME_AUTO=1")
  has "works under setopt $opt" "$o" "--resume sess-0001"
done

o=$(zsh -ic "export WARP_RESUME_STATE_DIR='$STATE'
export WARP_TERMINAL_SESSION_UUID='$PANE1'
MATCH=keepme; WARP_RESUME_AUTO=1; source '$ZSHLIB'; _warp_resume_reattach >/dev/null; print \"M=\$MATCH\"" </dev/null 2>&1 | tail -1)
is "does not clobber caller's \$MATCH" "$o" "M=keepme"

o=$(zsh -ic "export WARP_RESUME_STATE_DIR='$STATE'
export WARP_TERMINAL_SESSION_UUID='$PANE1'; source '$ZSHLIB'; warp-resume-list" </dev/null 2>&1)
has "warp-resume-list lists records" "$o" "sess-0001"

rm -rf "$T/gone"
printf 'claude-code\tsid-g\t%s\t%s\t\n' "$T/gone" "$(date +%s)" > "$STATE/$PANE3"
o=$(zrun "$PANE3" "WARP_RESUME_AUTO=1")
has "missing directory warns instead of resuming elsewhere" "$o" "directory is gone"
hasnt "missing directory does not launch claude" "$o" "CLAUDE argc"
rm -f "$STATE/$PANE3"

# stale record
printf 'claude-code\tsid-o\t%s\t1\t\n' "$PROJ" > "$STATE/$PANE3"
o=$(zrun "$PANE3" "WARP_RESUME_AUTO=1")
is "record older than MAX_AGE is ignored" "$o" ""
o=$(zsh -ic "export WARP_RESUME_STATE_DIR='$STATE'
export WARP_TERMINAL_SESSION_UUID='$PANE3'
WARP_RESUME_AUTO=1; source '$ZSHLIB'; warp-resume" </dev/null 2>&1)
has "warp-resume overrides MAX_AGE" "$o" "--resume sid-o"
rm -f "$STATE/$PANE3"

# ---------------------------------------------------------- Codex adapters
echo; echo "Codex and mixed harnesses"
NOW=$(date +%s)
hook "$PANE3" "{\"session_id\":\"$CODEX1\",\"cwd\":\"$PROJ\"}" codex-cli
hook "$PANE4" "{\"session_id\":\"$CODEX2\",\"cwd\":\"$PROJ\"}" codex-cli
is "Codex harness is recorded" "$(cut -f1 "$STATE/$PANE3")" "codex-cli"
is "record is 0600" "$(ls -l "$STATE/$PANE3" | cut -c2-10)" "rw-------"
o1=$(zrun "$PANE3" "WARP_RESUME_AUTO=1")
o2=$(zrun "$PANE4" "WARP_RESUME_AUTO=1")
has "Codex pane 1 resumes its exact ID without a daemon" "$o1" "CODEX argc=3 : resume --no-daemon $CODEX1"
has "Codex pane 2 resumes its own ID in the same cwd" "$o2" "resume --no-daemon $CODEX2"
hasnt "Codex pane 1 does not get pane 2's session" "$o1" "$CODEX2"
hasnt "Codex does not dispatch to Claude" "$o1" "CLAUDE"
has "Codex resumes in the recorded directory" "$o1" "CODEX cwd=$PROJ"
has "Codex receives the nested-shell guard" "$o1" "CODEX active=1"
has "Claude receives the nested-shell guard" "$(zrun "$PANE1" 'WARP_RESUME_AUTO=1')" "CLAUDE active=1"

o=$(zrun "$PANE3" "WARP_RESUME_CLAUDE_FLAGS=(--permission-mode bypassPermissions)
WARP_RESUME_CODEX_FLAGS=(--sandbox read-only --model 'model with spaces'); WARP_RESUME_AUTO=1")
has "Codex flags follow the resume subcommand" "$o" "CODEX argc=7 : resume --no-daemon --sandbox read-only --model model with spaces $CODEX1"
has "Codex flag values preserve argument boundaries" "$o" "CODEX arg=<model with spaces>"
hasnt "Claude flags do not leak into Codex" "$o" "bypassPermissions"
o=$(zrun "$PANE1" "WARP_RESUME_CODEX_FLAGS=(--sandbox read-only); WARP_RESUME_AUTO=1")
hasnt "Codex flags do not leak into Claude" "$o" "read-only"
o=$(zrun "$PANE3" "WARP_RESUME_CODEX_FLAGS='--sandbox read-only'; WARP_RESUME_AUTO=1")
has "scalar Codex flags warn" "$o" "WARP_RESUME_CODEX_FLAGS must be an array"
has "invalid scalar cannot remove --no-daemon" "$o" "CODEX argc=3 : resume --no-daemon $CODEX1"
for opt in nounset ksh_arrays sh_word_split extended_glob warn_create_global; do
  o=$(zrun "$PANE3" "setopt $opt; WARP_RESUME_AUTO=1")
  has "Codex works under setopt $opt" "$o" "resume --no-daemon $CODEX1"
done

hook "$PANE4" "{\"session_id\":\"switched-claude\",\"cwd\":\"$PROJ\"}"
o=$(zrun "$PANE4" "WARP_RESUME_AUTO=1")
has "switching from Codex to Claude replaces the binding" "$o" "--resume switched-claude"
hasnt "switching does not also launch the previous harness" "$o" "CODEX"
hook "$PANE4" "{\"session_id\":\"$CODEX2\",\"cwd\":\"$PROJ\"}" codex-cli
has "switching back to Codex replaces the binding" "$(zrun "$PANE4" 'WARP_RESUME_AUTO=1')" "$CODEX2"
o=$(zsh -c "WARP_RESUME_STATE_DIR='$STATE'; source '$ZSHLIB'; warp-resume-list")
has "list identifies Claude records" "$o" "claude-code"
has "list identifies Codex records" "$o" "codex-cli"
has "list includes both Codex panes" "$o" "$CODEX2"

o=$(zrun "$PANE3" "alias codex='codex --dangerously-bypass-approvals-and-sandbox'; WARP_RESUME_AUTO=1")
hasnt "Codex aliases cannot smuggle flags" "$o" "dangerously"
has "Codex binary is resolved despite an alias" "$o" "resume --no-daemon $CODEX1"
o=$(zrun "$PANE3" "export PATH='$T/empty'; alias codex='$BIN/codex'; WARP_RESUME_AUTO=1")
has "bare absolute Codex alias is supported" "$o" "resume --no-daemon $CODEX1"
o=$(zrun "$PANE3" "export PATH='$T/empty'; alias codex='$BIN/codex --sandbox read-only'; WARP_RESUME_AUTO=1")
hasnt "Codex alias with hidden flags is refused" "$o" "CODEX argc"
o=$(zrun "$PANE3" "hash codex=/nonexistent/codex; WARP_RESUME_AUTO=1")
hasnt "stale Codex hash does not spew a shell error" "$o" "no such file"
printf '#!/bin/sh\nprintf ATTACKER-CODEX-RAN\n' > "$EVIL/codex"; chmod +x "$EVIL/codex"
record "$PANE5" codex-cli "$CODEX1" "$EVIL" "$NOW"
o=$(zrun "$PANE5" "export PATH=\".:\$PATH\"; WARP_RESUME_AUTO=1")
hasnt "recorded cwd cannot supply the Codex binary" "$o" "ATTACKER"
has "the absolute PATH Codex runs instead" "$o" "CODEX argc"
o=$(zrun "$PANE3" "WARP_RESUME_AUTO=1; export STUB_EXIT=2")
has "Codex failures name the right harness" "$o" "codex exited 2"
has "Codex fresh-session guidance preserves --no-daemon" "$o" "codex --no-daemon"

for guard in 'export SSH_CONNECTION=remote' 'export SSH_TTY=/dev/remote' 'export WARP_RESUME_ACTIVE=1'; do
  is "reattach is silent with $guard" "$(zrun "$PANE3" "$guard; WARP_RESUME_AUTO=1")" ""
done
record "$PANE5" codex-cli "$CODEX1" "$PROJ" 1
is "stale Codex records are ignored" "$(zrun "$PANE5" 'WARP_RESUME_AUTO=1')" ""
o=$(zrun "$PANE5" "WARP_RESUME_AUTO=1; source '$ZSHLIB'; warp-resume")
has "manual Codex resume overrides the age limit" "$o" "resume --no-daemon $CODEX1"
rm -f "$STATE/$PANE5"

# --------------------------------------------------- malformed hook input
echo; echo "hook validation"
reject_hook "unknown harness" "{\"session_id\":\"s\",\"cwd\":\"$PROJ\"}" arbitrary-cli
reject_hook "malformed JSON" "{\"session_id\":\"s\",\"cwd\":\"$PROJ\""
reject_hook "non-object JSON" "[{\"session_id\":\"s\",\"cwd\":\"$PROJ\"}]"
reject_hook "non-string ID" "{\"session_id\":42,\"cwd\":\"$PROJ\"}"
reject_hook "non-string cwd" "{\"session_id\":\"s\",\"cwd\":42}"
reject_hook "missing top-level ID" "{\"meta\":{\"session_id\":\"nested\"},\"cwd\":\"$PROJ\"}"
reject_hook "wrong hook event" "{\"hook_event_name\":\"SubagentStart\",\"session_id\":\"s\",\"cwd\":\"$PROJ\"}"
reject_hook "non-string hook event" "{\"hook_event_name\":42,\"session_id\":\"s\",\"cwd\":\"$PROJ\"}"
reject_hook "Codex thread name instead of UUID" "{\"session_id\":\"thread-name\",\"cwd\":\"$PROJ\"}" codex-cli
reject_hook "Codex non-hex UUID" "{\"session_id\":\"g0000001-0000-4000-8000-000000000001\",\"cwd\":\"$PROJ\"}" codex-cli
reject_hook "newline in cwd" "{\"session_id\":\"s\",\"cwd\":\"$PROJ\\nextra\"}"
reject_hook "NUL in ID" "{\"session_id\":\"s\\u0000x\",\"cwd\":\"$PROJ\"}"
reject_hook "NUL in cwd" "{\"session_id\":\"s\",\"cwd\":\"$PROJ\\u0000x\"}"
reject_hook "surrogate in cwd" "{\"session_id\":\"s\",\"cwd\":\"$PROJ\\udc80\"}"
LONG=$(printf '%065d' 0)
reject_hook "oversized session ID" "{\"session_id\":\"$LONG\",\"cwd\":\"$PROJ\"}"
rm -f "$STATE/$PANE5"
o=$(WARP_TERMINAL_SESSION_UUID="$PANE5" WARP_RESUME_STATE_DIR="$STATE" "$HOOK" <<EOF
{"session_id":"s","cwd":"$PROJ"}
EOF
)
is "recorder requires an explicit harness" "$o" ""
[ ! -e "$STATE/$PANE5" ] && ok "missing harness writes nothing" || no "missing harness writes nothing" rejected written
for guard in SSH_CONNECTION SSH_TTY; do
  o=$(env "$guard=remote" WARP_TERMINAL_SESSION_UUID="$PANE5" WARP_RESUME_STATE_DIR="$STATE" \
    "$HOOK" codex-cli <<EOF
{"session_id":"$CODEX1","cwd":"$PROJ"}
EOF
)
  is "hook is silent with $guard" "$o" ""
  [ ! -e "$STATE/$PANE5" ] && ok "hook skips $guard" || no "hook skips $guard" rejected written
done
hook "$LONG" "{\"session_id\":\"s\",\"cwd\":\"$PROJ\"}"
[ ! -e "$STATE/$LONG" ] && ok "oversized pane UUID is rejected" || no "oversized pane UUID is rejected" rejected written
(cd "$PROJ" && hook "$PANE5" '{"session_id":"cwd-fallback"}')
is "missing cwd falls back to the launch directory" "$(cut -f3 "$STATE/$PANE5")" "$PROJ"
PATH="$NOPY:$PATH" hook "$PANE5" "{\"session_id\":\"$CODEX1\",\"cwd\":\"$PROJ\"}" codex-cli
is "Codex hook works without working Python" "$(cut -f2 "$STATE/$PANE5")" "$CODEX1"
mkdir -p "$PROJ/café"
PATH="$NOPY:$PATH" hook "$PANE5" "{\"session_id\":\"utf8-path\",\"cwd\":\"$PROJ/café\",\"model\":\"π\"}"
is "fallback preserves literal Unicode paths" "$(cut -f3 "$STATE/$PANE5")" "$PROJ/café"
for mode in native fallback; do
  HOOK_PATH="$PATH"; [ "$mode" = fallback ] && HOOK_PATH="$NOPY:$PATH"
  for bad in 'raw\000id' 'raw\303('; do
    record "$PANE5" claude-code preserved-binding "$PROJ" "$NOW"
    before=$(cat "$STATE/$PANE5")
    o=$(printf '{"session_id":"%b","cwd":"%s"}' "$bad" "$PROJ" \
      | env PATH="$HOOK_PATH" WARP_RESUME_STATE_DIR="$STATE" WARP_TERMINAL_SESSION_UUID="$PANE5" "$HOOK" claude-code 2>&1)
    is "$mode: raw invalid JSON bytes are silent" "$o" ""
    is "$mode: raw invalid JSON bytes preserve the binding" "$(cat "$STATE/$PANE5")" "$before"
  done
done
rm -f "$STATE/$PANE5"

# ------------------------------------------------------- malformed records
echo; echo "record validation"
silent_record "unknown record harness is silent" arbitrary-cli s "$PROJ" "$NOW"
silent_record "record cannot choose an executable" "$BIN/codex" "$CODEX1" "$PROJ" "$NOW"
silent_record "empty harness is silent" "" s "$PROJ" "$NOW"
silent_record "empty ID is silent" claude-code "" "$PROJ" "$NOW"
silent_record "empty cwd is silent" claude-code s "" "$NOW"
silent_record "empty timestamp is silent" claude-code s "$PROJ" ""
silent_record "relative transcript in a record is silent" claude-code s "$PROJ" "$NOW" relative.jsonl
silent_record "control character in transcript is silent" claude-code s "$PROJ" "$NOW" "$T/"$'\e'"s.jsonl"
silent_record "Codex record must contain a UUID" codex-cli thread-name "$PROJ" "$NOW"
silent_record "oversized record ID is silent" claude-code "$LONG" "$PROJ" "$NOW"
printf 'claude-code\ts\t%s\t%s\t\t--sandbox\n' "$PROJ" "$NOW" > "$STATE/$PANE5"
is "extra record fields are silent" "$(zrun "$PANE5" 'WARP_RESUME_AUTO=1')" ""
printf 's\t%s\t%s\t\n' "$PROJ" "$NOW" > "$STATE/$PANE5"
is "legacy four-column records are not misinterpreted" "$(zrun "$PANE5" 'WARP_RESUME_AUTO=1')" ""
for trailing in $'extra line\n' 'unterminated extra line' $'\n'; do
  record "$PANE5" claude-code multi-line "$PROJ" "$NOW"
  printf '%s' "$trailing" >> "$STATE/$PANE5"
  is "additional record lines or bytes are silent" "$(zrun "$PANE5" 'WARP_RESUME_AUTO=1')" ""
done
record "$PANE5" claude-code empty-transcript "$PROJ" "$NOW"
has "empty optional transcript survives the split" "$(zrun "$PANE5" 'WARP_RESUME_AUTO=1')" "--resume empty-transcript"
is "oversized pane identity is silent on read" "$(zrun "$LONG" 'WARP_RESUME_AUTO=1')" ""
o=$(zsh -c "WARP_RESUME_STATE_DIR='$STATE'; WARP_TERMINAL_SESSION_UUID='$PANE5'
source '$ZSHLIB'; warp-resume-forget")
has "forget removes only the current binding" "$o" "forgotten"
[ ! -e "$STATE/$PANE5" ] && ok "forgotten record is gone" || no "forgotten record is gone" removed exists
[ -e "$STATE/$PANE3" ] && ok "forget leaves other panes alone" || no "forget leaves other panes alone" exists missing
# ---------------------------------------------------------------- details
# The resume prompt shows the session's title, age and last message, read
# from Claude Code's transcript. That transcript is untrusted text.
echo; echo "details (transcript summary under the prompt)"
TX="$T/transcripts"; mkdir -p "$TX/-proj"
python3 - "$TX/-proj/sess-0001.jsonl" "$T" <<'PYEOF'
import json, sys
t = sys.argv[2]
rows = [
  {"type": "summary", "summary": "Generated summary", "leafUuid": "x"},
  {"type": "user", "message": {"role": "user", "content": "<command-name>/clear</command-name>"}},
  {"type": "user", "isMeta": True, "message": {"role": "user", "content": "META-SHOULD-NOT-SHOW"}},
  {"type": "user", "message": {"role": "user", "content": "Draft the methods\nsection"}},
  {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "TOOLRESULT-SHOULD-NOT-SHOW"}]}},
  {"type": "user", "message": {"role": "user", "content": [{"type": "text",
     # %F{1} goes first: the message is truncated at 90 chars and $t (the
     # temp dir) is long on macOS, so anything after it would be cut off.
     "text": "tighten the table %F{1}red \u001b[2J\u001b]0;PWNED\u0007 \u202egnp $(touch " + t + "/CANARY3)"}]}},
  {"type": "custom-title", "customTitle": "Methods draft", "sessionId": "sess-0001"},
]
with open(sys.argv[1], "w") as f:
    for r in rows: f.write(json.dumps(r) + "\n")
    f.write("{not json\n")
PYEOF
dz() { zsh -c "setopt prompt_subst; WARP_RESUME_CLAUDE_TRANSCRIPT_DIR='$TX'; ${2-}
source '$ZSHLIB'; _warp_resume_details claude-code '$1' '${3-}'" </dev/null 2>&1; }
o=$(dz sess-0001)
has   "custom title (/rename) is shown" "$o" "Methods draft"
has   "prompt count counts only typed prompts" "$o" "2 prompts"
has   "last typed message is shown" "$o" "last:"
has   "…with its text" "$o" "tighten the table"
hasnt "slash-command noise is skipped" "$o" "command-name"
hasnt "isMeta messages are skipped" "$o" "META-SHOULD-NOT-SHOW"
hasnt "tool results are skipped" "$o" "TOOLRESULT-SHOULD-NOT-SHOW"
hasnt "no ESC from transcript reaches the terminal" "$o" $'\e[2J'
hasnt "no OSC title-set from transcript" "$o" $'\e]0;'
hasnt "no BEL from transcript" "$o" $'\a'
hasnt "no bidi override from transcript" "$o" $'‮'
has   "%-escapes in transcript are printed literally, not expanded" "$o" "%F{1}red"
[ -f "$T/CANARY3" ] && no "no command execution via transcript + PROMPT_SUBST" "no canary" "CANARY3 CREATED" \
                    || ok "no command execution via transcript + PROMPT_SUBST"
o=$(dz sess-0001 "setopt ksh_arrays nounset sh_word_split")
has   "details work under ksh_arrays/nounset/sh_word_split" "$o" "Methods draft"
o=$(dz no-such-session)
is    "no transcript prints nothing" "$o" ""
o=$(dz '../../etc' )
is    "path-shaped id prints nothing" "$o" ""
printf '{"type":"user","message":{"content":"only one"}}\n' > "$TX/-proj/sess-0002.jsonl"
o=$(dz sess-0002)
has   "no title falls back to first prompt" "$o" "only one"
hasnt "last line omitted when it equals the title" "$o" "last:"
o=$(dz sess-0002 "export PATH='$NOPY'")
has   "without working python3, still shows age and size" "$o" "1 KB"
o=$(dz sess-0002 "export PATH='$T/empty'")
has "without any Python binary, Claude still shows size" "$o" "1 KB"
hasnt "without any Python binary, Claude text is omitted" "$o" "only one"

# ------------------------------------------------------- transcript lookup
echo; echo "transcript lookup and recorded paths"
mkdir -p "$TX/-recorded" "$TX-outside"
printf '{"type":"user","message":{"content":"Recorded Claude path"}}\n' > "$TX/-recorded/sess-0002.jsonl"
touch -t 200001010000 "$TX/-recorded/sess-0002.jsonl"
has "recorded Claude transcript is preferred over newer matches" \
  "$(dz sess-0002 "" "$TX/-recorded/sess-0002.jsonl")" "Recorded Claude path"
has "missing recorded Claude transcript falls back by exact ID" \
  "$(dz sess-0002 "" "$TX/missing/sess-0002.jsonl")" "only one"
printf '{"type":"user","message":{"content":"OUTSIDE-ROOT"}}\n' > "$TX-outside/sess-0002.jsonl"
o=$(dz sess-0002 "" "$TX-outside/sess-0002.jsonl")
hasnt "transcript root uses a component boundary" "$o" "OUTSIDE-ROOT"
has "out-of-root recorded path falls back safely" "$o" "only one"
ln -s "$TX-outside" "$TX/-escape"
o=$(dz sess-0002 "" "$TX/-escape/sess-0002.jsonl")
hasnt "symlink escaping the transcript root is not read" "$o" "OUTSIDE-ROOT"
has "unsafe symlink candidate does not hide a safe fallback" "$o" "only one"
mkdir -p "$TX/-parent" "$TX-outside/deep"
ln -s "$TX-outside/deep" "$TX/-parent/link"
o=$(dz sess-0002 "" "$TX/-parent/link/../sess-0002.jsonl")
hasnt "symlink plus parent traversal cannot escape Claude root" "$o" "OUTSIDE-ROOT"
has "Claude parent traversal falls back to a safe native file" "$o" "only one"
ln -s "$TX" "$T/claude-link"
has "symlinked Claude root accepts a canonical recorded path" \
  "$(dz sess-0002 "WARP_RESUME_CLAUDE_TRANSCRIPT_DIR='$T/claude-link'" "$TX/-recorded/sess-0002.jsonl")" "Recorded Claude path"
SPECIAL="$T/claude [literal]"; mkdir -p "$SPECIAL/project"
cp "$TX/-proj/sess-0002.jsonl" "$SPECIAL/project/sess-0002.jsonl"
has "glob characters in transcript roots stay literal" \
  "$(dz sess-0002 "emulate sh; WARP_RESUME_CLAUDE_TRANSCRIPT_DIR='$SPECIAL'")" "only one"
mkfifo "$TX/-recorded/fifo-session.jsonl"
is "details never open a transcript FIFO" "$(dz fifo-session "" "$TX/-recorded/fifo-session.jsonl")" ""

hook "$PANE5" "{\"session_id\":\"sess-0002\",\"cwd\":\"$PROJ\",\"transcript_path\":\"$TX/-proj/sess-0002.jsonl\"}"
is "hook retains an absolute matching transcript path" "$(cut -f5 "$STATE/$PANE5")" "$TX/-proj/sess-0002.jsonl"
for transcript in 'relative.jsonl' "$TX/wrong-id.jsonl" "$TX/sess-0002.jsonl\\u0000"; do
  hook "$PANE5" "{\"session_id\":\"sess-0002\",\"cwd\":\"$PROJ\",\"transcript_path\":\"$transcript\"}"
  is "unusable optional path does not lose the session" "$(cut -f2 "$STATE/$PANE5")" "sess-0002"
  is "unusable optional path is omitted" "$(cut -f5 "$STATE/$PANE5")" ""
done
rm -f "$STATE/$PANE5"

# ------------------------------------------------------- Codex transcripts
echo; echo "Codex transcript details"
CX="$T/codex sessions [literal]"; CI="$T/session_index.jsonl"
mkdir -p "$CX/2026/10/01" "$CX/relocated" "$CX-outside"
CF="$CX/2026/10/01/rollout-2026-10-01T00-00-00-$CODEX1.jsonl"
LF="$CX/2026/10/01/rollout-2026-10-01T00-00-01-$CODEX2.jsonl"
python3 - "$CF" "$LF" "$CI" "$CODEX1" "$CODEX2" <<'PYEOF'
import json, sys
modern, legacy, index, sid1, sid2 = sys.argv[1:]
def user(item_id, text):
    return {"type": "event_msg", "payload": {"type": "item_completed", "item": {
        "type": "UserMessage", "id": item_id, "client_id": "client-" + item_id,
        "content": [{"type": "text", "text": text, "text_elements": []}]}}}
first = user("one", "Plan Node.js upgrade")
last = "$(touch C4) %F{1}red \u001b[2J\u001b]0;PWNED\u0007 \u202e\u001f finalize the plan"
rows = [
    {"type": "session_meta", "payload": {"id": sid1}},
    {"type": "response_item", "payload": {"type": "message", "role": "user",
        "content": [{"type": "input_text", "text": "INJECTED-AGENTS-CONTEXT"}]}},
    {"type": "event_msg", "payload": {"type": "item_started", "item": first["payload"]["item"]}},
    first, first,  # completed-item duplicates share an ID and count once
    user("two", "Plan Node.js upgrade"),  # a real repeated prompt still counts
    user("noise", "<hook-context>NOISE-SHOULD-NOT-SHOW</hook-context>"),
    {"type": "event_msg", "payload": {"type": "item_completed", "item": {
        "type": "UserMessage", "id": "bad-content", "content": [None, 7, {"type": "image"}]}}},
    user("three", last),
]
for item_id, text in (("one", "Plan Node.js upgrade"), ("two", "Plan Node.js upgrade"), ("three", last)):
    rows += [
        {"type": "event_msg", "payload": {"type": "user_message", "message": text, "client_id": "client-" + item_id}},
        {"type": "response_item", "payload": {"type": "message", "role": "user",
            "content": [{"type": "input_text", "text": text}]}},
    ]
with open(modern, "w") as f:
    for row in rows: f.write(json.dumps(row) + "\n")
    f.write('{"type":"event_msg","payload":\n')
with open(legacy, "w") as f:
    for text in ("Legacy first prompt", "Legacy last prompt"):
        f.write(json.dumps({"type": "event_msg", "payload": {
            "type": "user_message", "message": text}}) + "\n")
    f.write(json.dumps({"type": "response_item", "payload": {"type": "message",
        "role": "user", "content": [{"type": "input_text", "text": "LEGACY-CONTEXT"}]}}) + "\n")
with open(index, "w") as f:
    for row in (
        {"id": sid1, "thread_name": "Old Codex name"},
        {"id": sid1, "thread_name": "Latest Codex name %F{2}green \u001b[2J"},
        {"id": sid2, "thread_name": "Different thread"},
    ): f.write(json.dumps(row) + "\n")
    f.write("{not json\n")
PYEOF
cdz() {
  (cd "$T" && zsh -c "setopt prompt_subst
WARP_RESUME_CODEX_TRANSCRIPT_DIR='$CX'; WARP_RESUME_CODEX_INDEX='$CI'; ${2-}
source '$ZSHLIB'; _warp_resume_details codex-cli '$1' '${3-}'" </dev/null 2>&1)
}
o=$(cdz "$CODEX1")
has "Codex uses the latest matching name index entry" "$o" "Latest Codex name"
hasnt "old Codex names do not override the latest" "$o" "Old Codex name"
hasnt "another thread's name does not leak" "$o" "Different thread"
has "modern Codex prompts count without duplicate representations" "$o" "3 prompts"
has "real repeated prompts with different IDs still count" "$o" "3 prompts"
has "modern Codex last typed message is shown" "$o" "last:"
has "Codex last message text is retained" "$o" "finalize the plan"
hasnt "Codex raw user-role context is ignored" "$o" "INJECTED-AGENTS-CONTEXT"
hasnt "Codex hook-context noise is ignored" "$o" "NOISE-SHOULD-NOT-SHOW"
hasnt "Codex ESC controls are stripped" "$o" $'\e[2J'
hasnt "Codex OSC controls are stripped" "$o" $'\e]0;'
hasnt "Codex BEL controls are stripped" "$o" $'\a'
hasnt "Codex bidi controls are stripped" "$o" $'\342\200\256'
hasnt "Codex field separators cannot split the parser output" "$o" $'\x1f'
has "Codex title prompt escapes are printed literally" "$o" "%F{2}green"
has "Codex message prompt escapes are printed literally" "$o" "%F{1}red"
[ ! -e "$T/C4" ] && ok "Codex transcript cannot execute prompt substitutions" \
  || no "Codex transcript cannot execute prompt substitutions" "no canary" "C4 CREATED"
has "Codex details work under hostile shell options" \
  "$(cdz "$CODEX1" 'setopt ksh_arrays nounset sh_word_split')" "Latest Codex name"
o=$(cdz "$CODEX2" "WARP_RESUME_CODEX_INDEX='$T/missing-index'")
has "legacy Codex user events are supported" "$o" "2 prompts"
has "missing name index falls back to the first prompt" "$o" "Legacy first prompt"
has "legacy Codex last prompt is shown" "$o" "Legacy last prompt"
hasnt "legacy raw context is not counted" "$o" "LEGACY-CONTEXT"
o=$(cdz "$CODEX1" "export PATH='$NOPY'")
has "Codex without Python still shows transcript size" "$o" "KB"
hasnt "Codex without Python does not print transcript text" "$o" "Latest Codex name"
o=$(cdz "$CODEX1" "export PATH='$T/empty'")
has "without any Python binary, Codex still shows size" "$o" "KB"
hasnt "without any Python binary, Codex text is omitted" "$o" "Latest Codex name"
is "missing Codex transcript is silent" "$(cdz 00000009-0000-4000-8000-000000000009)" ""

RF="$CX/relocated/rollout-recorded-$CODEX1.jsonl"
printf '{"type":"event_msg","payload":{"type":"user_message","message":"Recorded Codex path"}}\n' > "$RF"
has "recorded Codex path supports relocated in-root rollouts" \
  "$(cdz "$CODEX1" "WARP_RESUME_CODEX_INDEX='$T/missing-index'" "$RF")" "Recorded Codex path"
OF="$CX-outside/rollout-outside-$CODEX1.jsonl"
printf '{"type":"event_msg","payload":{"type":"user_message","message":"OUTSIDE-CODEX-ROOT"}}\n' > "$OF"
o=$(cdz "$CODEX1" "" "$OF")
hasnt "Codex recorded path cannot escape the root" "$o" "OUTSIDE-CODEX-ROOT"
has "unsafe Codex path falls back to its exact native rollout" "$o" "3 prompts"
ln -s "$OF" "$CX/relocated/rollout-link-$CODEX1.jsonl"
hasnt "Codex recorded symlink cannot escape the root" \
  "$(cdz "$CODEX1" "" "$CX/relocated/rollout-link-$CODEX1.jsonl")" "OUTSIDE-CODEX-ROOT"
mkdir -p "$CX/relocated/parent" "$CX-outside/deep"
ln -s "$CX-outside/deep" "$CX/relocated/parent/link"
o=$(cdz "$CODEX1" "" "$CX/relocated/parent/link/../rollout-outside-$CODEX1.jsonl")
hasnt "symlink plus parent traversal cannot escape Codex root" "$o" "OUTSIDE-CODEX-ROOT"
has "Codex parent traversal falls back to its exact native file" "$o" "3 prompts"
ln -s "$CX" "$T/codex-link"
has "symlinked Codex root accepts its canonical rollout path" \
  "$(cdz "$CODEX1" "WARP_RESUME_CODEX_TRANSCRIPT_DIR='$T/codex-link'" "$CF")" "3 prompts"
o=$(cdz "$CODEX2" "WARP_RESUME_CODEX_INDEX='$T/missing-index'" "$CF")
has "wrong-ID recorded Codex path is ignored" "$o" "Legacy first prompt"
mkfifo "$T/index-fifo"
has "Codex index FIFO is never opened" \
  "$(cdz "$CODEX1" "WARP_RESUME_CODEX_INDEX='$T/index-fifo'")" "Plan Node.js upgrade"
hook "$PANE5" "{\"session_id\":\"$CODEX1\",\"cwd\":\"$PROJ\",\"transcript_path\":\"$CF\"}" codex-cli
is "Codex hook retains its rollout path" "$(cut -f5 "$STATE/$PANE5")" "$CF"
rm -f "$STATE/$PANE5"

mkdir -p "$T/claude-home" "$T/codex-home"
ln -s "$TX" "$T/claude-home/projects"
ln -s "$CX" "$T/codex-home/sessions"
cp "$CI" "$T/codex-home/session_index.jsonl"
o=$(zsh -c "CLAUDE_CONFIG_DIR='$T/claude-home'; CODEX_HOME='$T/codex-home'
source '$ZSHLIB'; _warp_resume_details claude-code sess-0001
_warp_resume_details codex-cli '$CODEX1'")
has "CLAUDE_CONFIG_DIR controls default transcript lookup" "$o" "Methods draft"
has "CODEX_HOME controls default rollout and index lookup" "$o" "Latest Codex name"
HYBRID=00000003-0000-4000-8000-000000000003
cat > "$CX/2026/10/01/rollout-hybrid-$HYBRID.jsonl" <<'EOF'
{"type":"event_msg","payload":{"type":"user_message","message":"Hybrid original first"}}
{"type":"event_msg","payload":{"type":"user_message","message":"Hybrid older second"}}
{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"hybrid-new","content":[{"type":"text","text":"Hybrid modern third"}]}}}
EOF
o=$(cdz "$HYBRID")
has "mixed-generation Codex history retains legacy-only prompts" "$o" "3 prompts"
has "mixed-generation Codex title retains the original first prompt" "$o" "Hybrid original first"
has "mixed-generation Codex last message uses the latest format" "$o" "Hybrid modern third"
cat > "$CX/2026/10/01/rollout-hybrid-$HYBRID.jsonl" <<'EOF'
{"type":"event_msg","payload":{"type":"user_message","message":"Repeat this prompt"}}
{"type":"event_msg","payload":{"type":"user_message","message":"Repeat this prompt"}}
{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"fresh-repeat","content":[{"type":"text","text":"Repeat this prompt"}]}}}
EOF
has "identical uncorrelated prompts across formats all count" "$(cdz "$HYBRID")" "3 prompts"
cat > "$CX/2026/10/01/rollout-hybrid-$HYBRID.jsonl" <<'EOF'
{"type":"event_msg","payload":{"type":"user_message","client_id":"shared","message":"Pair first"}}
{"type":"event_msg","payload":{"type":"user_message","client_id":"shared","message":"Pair real repeat"}}
{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"pair-one","client_id":"shared","content":[{"type":"text","text":"Pair first"}]}}}
EOF
o=$(cdz "$HYBRID")
has "correlated double views are consumed one-to-one" "$o" "2 prompts"
has "unmatched repeated client IDs are not globally dropped" "$o" "Pair real repeat"
cat > "$CX/2026/10/01/rollout-hybrid-$HYBRID.jsonl" <<'EOF'
{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"joined","client_id":"joined-client","content":[{"type":"text","text":"Join"},{"type":"text","text":"ed text"}]}}}
{"type":"event_msg","payload":{"type":"user_message","client_id":"joined-client","message":"Joined text"}}
EOF
o=$(cdz "$HYBRID")
has "Codex text blocks use native concatenation" "$o" "Joined text"
has "paired text representations count once" "$o" "1 prompt"

# ---------------------------------------------------------------- pty tests
echo; echo "interactive (pty)"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import pty' 2>/dev/null; then
  cat > "$T/ptyh.py" <<'PYEOF'
import os, pty, sys, select, time, fcntl, signal, secrets
rc = sys.argv[1]
reply = sys.argv[2].encode() + b"\n" if len(sys.argv) > 2 else b"n\n"
after = sys.argv[3].encode() + b"\n" if len(sys.argv) > 3 else b""
out = b""
pid, fd = pty.fork()
if pid == 0:
    os.environ["ZDOTDIR"] = os.path.dirname(rc)
    os.execvp("zsh", ["zsh", "-i"]); os._exit(1)
# Hard deadline. Whatever else goes wrong below (a pty read that never returns,
# a child that ignores exit), this test ends in 20s with what was captured.
def _deadline(*_):
    try: os.kill(pid, 9); os.waitpid(pid, 0)
    except Exception: pass
    sys.stdout.write(out.decode(errors="replace") + "\n[ptyh: deadline hit]\n"); sys.stdout.flush()
    os._exit(1)
signal.signal(signal.SIGALRM, _deadline); signal.alarm(20)
# Non-blocking master: on macOS a read on the master after the slave has
# closed can block forever instead of returning EOF, hanging the whole suite
# on the trailing read below (intermittent -- it's a race with zsh's exit).
fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.fcntl(fd, fcntl.F_GETFL) | os.O_NONBLOCK)
sent = ready = False; t0 = time.time()
while time.time() - t0 < 8:
    r, _, _ = select.select([fd], [], [], 0.5)
    if r:
        try: d = os.read(fd, 4096)
        except OSError: break
        if not d: break
        out += d
        if not sent and b"[Y/n]" in out:
            os.write(fd, reply)
            sent = True
        if b"PTY-READY>" in out:
            ready = True
            break
nonce = "PTY-DONE-" + secrets.token_hex(16)
finish = after + ("print -r -- " + nonce + "\nexit 0\n").encode()
status = None
eof = False
try:
    os.write(fd, finish)
    t1 = time.time()
    while time.time() - t1 < 5:
        if not eof:
            r, _, _ = select.select([fd], [], [], 0.1)
            if r:
                try: d = os.read(fd, 65536)
                except OSError: d = b""
                if d: out += d
                else: eof = True
        else:
            time.sleep(0.01)
        if status is None:
            ended, child_status = os.waitpid(pid, os.WNOHANG)
            if ended: status = child_status
        if eof and status is not None: break
except OSError: pass
if status is None:
    try: os.kill(pid, 9); os.waitpid(pid, 0)
    except OSError: pass
os.close(fd)
text = out.decode(errors="replace")
sys.stdout.write(text)
# A prompt-looking line or echoed command is not proof of readiness. Require
# a random response on its own line and a normal shell exit; forced kills fail.
completed = "\n" + nonce + "\n" in text.replace("\r", "")
clean_exit = status is not None and os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0
if not (ready and completed and clean_exit):
    sys.stdout.write("\n[ptyh: command handshake or normal exit failed]\n")
    sys.exit(1)
PYEOF
  mkrc() {
    mkdir -p "$T/rc$1"
    printf "builtin cd '%s'\n%s\nPROMPT='PTY-READY> '\nRPROMPT=''\n" "$T" "$2" > "$T/rc$1/.zshrc"
  }
  ptyrun() {
    local status=0 name="${1%/.zshrc}"
    o=$(python3 "$T/ptyh.py" "$@" 2>&1) || status=$?
    is "PTY ${name##*/} completed" "$status" 0
  }
  BASE="export WARP_RESUME_STATE_DIR='$STATE'
export WARP_TERMINAL_SESSION_UUID='$PANE1'"

  mkrc A "$BASE
WARP_RESUME_AUTO=1
source '$ZSHLIB'
print AFTER-ZSHRC"
  ptyrun "$T/rcA/.zshrc"
  has "precmd hook fires in a real terminal" "$o" "CLAUDE argc"
  # .zshrc must finish BEFORE claude launches (powerlevel10k instant prompt)
  a=$(printf '%s' "$o" | grep -n 'AFTER-ZSHRC' | head -1 | cut -d: -f1)
  c=$(printf '%s' "$o" | grep -n 'CLAUDE argc'  | head -1 | cut -d: -f1)
  { [ -n "$a" ] && [ -n "$c" ] && [ "$a" -lt "$c" ]; } \
    && ok ".zshrc completes before claude launches" \
    || no ".zshrc completes before claude launches" "AFTER-ZSHRC first" "zshrc=$a claude=$c"

  mkrc B "$BASE
WARP_RESUME_AUTO=1
source '$ZSHLIB'
source '$ZSHLIB'"
  ptyrun "$T/rcB/.zshrc"
  n=$(printf '%s' "$o" | grep -c 'CLAUDE argc')
  is "double source launches claude once" "$n" "1"

  mkrc C "$BASE
WARP_RESUME_DISABLE=1
source '$ZSHLIB'
print DISABLED-OK"
  ptyrun "$T/rcC/.zshrc"
  hasnt "WARP_RESUME_DISABLE=1 suppresses everything" "$o" "CLAUDE argc"

  mkrc D "$BASE
source '$ZSHLIB'"
  ptyrun "$T/rcD/.zshrc" n
  has "prompt is shown" "$o" "resume?"
  hasnt "answering n does not launch claude" "$o" "CLAUDE argc"

  mkrc E "$BASE
WARP_RESUME_CLAUDE_TRANSCRIPT_DIR='$TX'
source '$ZSHLIB'"
  ptyrun "$T/rcE/.zshrc" n
  has "prompt shows the session title" "$o" "Methods draft"
  has "prompt shows the last message" "$o" "tighten the table"
  mkrc F "$BASE
WARP_RESUME_CLAUDE_TRANSCRIPT_DIR='$TX'
WARP_RESUME_DETAILS=0
source '$ZSHLIB'"
  ptyrun "$T/rcF/.zshrc" n
  hasnt "WARP_RESUME_DETAILS=0 hides details" "$o" "Methods draft"
  has   "…but still prompts" "$o" "resume?"

  ptyrun "$T/rcD/.zshrc" ""
  has "bare enter accepts" "$o" "CLAUDE argc"
  has "accepting cds into the recorded directory" "$o" "CLAUDE cwd=$PROJ"

  CBASE="export WARP_RESUME_STATE_DIR='$STATE'
export WARP_TERMINAL_SESSION_UUID='$PANE3'
WARP_RESUME_CODEX_TRANSCRIPT_DIR='$CX'
WARP_RESUME_CODEX_INDEX='$CI'"
  mkrc G "$CBASE
WARP_RESUME_AUTO=1
source '$ZSHLIB'
source '$ZSHLIB'
print CODEX-ZSHRC-COMPLETE"
  ptyrun "$T/rcG/.zshrc"
  has "Codex one-shot hook fires in a real terminal" "$o" "CODEX argc=3 : resume --no-daemon $CODEX1"
  n=$(printf '%s' "$o" | grep -c 'CODEX argc')
  is "double source launches Codex once" "$n" 1
  a=$(printf '%s' "$o" | grep -n 'CODEX-ZSHRC-COMPLETE' | cut -d: -f1)
  c=$(printf '%s' "$o" | grep -n 'CODEX argc' | cut -d: -f1)
  { [ -n "$a" ] && [ -n "$c" ] && [ "$a" -lt "$c" ]; } \
    && ok ".zshrc completes before Codex launches" \
    || no ".zshrc completes before Codex launches" "zshrc first" "zshrc=$a codex=$c"

  mkrc H "$CBASE
setopt prompt_subst
WARP_RESUME_CODEX_FLAGS=(--sandbox read-only)
source '$ZSHLIB'
print CODEX-ZSHRC-COMPLETE"
  ptyrun "$T/rcH/.zshrc" n 'print -r -- "AFTER-DECLINE=$PWD"'
  has "Codex prompt identifies the harness" "$o" "codex"
  has "Codex prompt shows mandatory and configured options" "$o" "--no-daemon --sandbox read-only"
  has "Codex prompt shows its indexed title" "$o" "Latest Codex name"
  has "Codex prompt shows its last message" "$o" "finalize the plan"
  hasnt "declining Codex does not launch a CLI" "$o" "CODEX argc"
  has "declining leaves the shell in its original directory" "$o" "AFTER-DECLINE=$T"
  [ ! -e "$T/C4" ] && ok "interactive Codex details cannot execute substitutions" \
    || no "interactive Codex details cannot execute substitutions" "no canary" "C4 CREATED"
  ptyrun "$T/rcH/.zshrc" ""
  has "bare enter resumes Codex with configured flags" "$o" "resume --no-daemon --sandbox read-only $CODEX1"
  has "accepting Codex enters the recorded directory" "$o" "CODEX cwd=$PROJ"
  ptyrun "$T/rcH/.zshrc" $'\003'
  has "Ctrl-C cannot interrupt unfinished .zshrc" "$o" "CODEX-ZSHRC-COMPLETE"
  hasnt "Ctrl-C at the resume prompt does not launch Codex" "$o" "CODEX argc"

  for guard in WARP_RESUME_DISABLE WARP_RESUME_ACTIVE SSH_CONNECTION; do
    mkrc "guard-$guard" "$CBASE
export $guard=1
WARP_RESUME_AUTO=1
source '$ZSHLIB'"
    ptyrun "$T/rcguard-$guard/.zshrc"
    hasnt "automatic Codex resume respects $guard" "$o" "CODEX argc"
  done
  mkrc I "$CBASE
WARP_RESUME_DETAILS=0
source '$ZSHLIB'"
  ptyrun "$T/rcI/.zshrc" n
  hasnt "details toggle also hides Codex details" "$o" "Latest Codex name"
  has "Codex still prompts with details disabled" "$o" "resume?"
  mkrc J "$BASE
WARP_RESUME_CLAUDE_FLAGS=(--permission-mode=plan)
source '$ZSHLIB'"
  ptyrun "$T/rcJ/.zshrc" n
  has "Claude permission-mode equals form is displayed" "$o" "plan"

  record "$PANE5" claude-code cwd-injection "$T/\$(touch $T/CANARY)x" "$NOW"
  mkrc cwd "export WARP_RESUME_STATE_DIR='$STATE'
export WARP_TERMINAL_SESSION_UUID='$PANE5'
setopt prompt_subst
source '$ZSHLIB'"
  ptyrun "$T/rccwd/.zshrc" n
  has "malicious cwd reaches the actual consent prompt" "$o" "resume?"
  has "malicious cwd is visibly printed as literal data" "$o" "\$(touch $T/CANARY)x"
  hasnt "declining malicious cwd does not launch the CLI" "$o" "CLAUDE argc"
  [ ! -e "$T/CANARY" ] && ok "PTY cwd display cannot execute prompt substitutions" \
    || no "PTY cwd display cannot execute prompt substitutions" "no canary" "CANARY CREATED"
  rm -f "$STATE/$PANE5"

  mkrc stuck 'print -r -- "PTY-READY> "
while builtin read -r line; do :; done'
  status=0
  o=$(python3 "$T/ptyh.py" "$T/rcstuck/.zshrc" 2>&1) || status=$?
  is "PTY helper rejects a fake ready marker and stuck shell" "$status" 1
else
  sk "interactive prompt tests" "python3 with pty module not available"
fi

echo
echo "----------------------------------------"
printf 'pass %d   fail %d   skip %d\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ] || exit 1
