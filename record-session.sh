#!/bin/sh
# ---------------------------------------------------------------------------
# Claude Code / Codex CLI SessionStart hook.
#
# Records which harness and session are live in which Warp pane, so when Warp
# restores that pane after a restart the shell can reattach it to its OWN
# conversation -- not just "the newest one in this directory".
#
# The pane key is $WARP_TERMINAL_SESSION_UUID, which Warp exports into every
# local pane's shell. It is the same pane UUID Warp persists in its snapshot
# database, so a restored pane comes back with the identical value. The
# variable is undocumented; the format below is from Warp's own unit tests.
#
# Install: see README.md
# ---------------------------------------------------------------------------

# POSIX sh, no bashisms: Claude Code runs hook commands through `sh -c`, and
# /bin/sh is dash on many Linux systems, which rejects `set -o pipefail`.
set -u

STATE_DIR="${WARP_RESUME_STATE_DIR:-$HOME/.warp-resume/panes}"
harness="${1:-}"
case "$harness" in
  claude-code|codex-cli) ;;
  *) exit 0 ;;
esac

pane="${WARP_TERMINAL_SESSION_UUID:-}"

# Not running inside a Warp pane (ssh, CI, a plain terminal). Nothing to
# record. Exit 0 so we never interfere with the harness starting up.
[ -n "$pane" ] || exit 0
[ -z "${SSH_CONNECTION:-}${SSH_TTY:-}" ] || exit 0

# Reject anything that isn't the bare-hex UUID Warp emits, so a hostile value
# can never become a path component.
case "$pane" in
  *[!0-9a-fA-F]*) exit 0 ;;
  "")             exit 0 ;;
esac
[ "${#pane}" -le 64 ] || exit 0

# Raw NUL is forbidden in JSON, but shell substitution would discard it.
# Substitute another forbidden control before capture; valid JSON is unchanged.
payload="$(LC_ALL=C tr '\000' '\001')"

# Both harnesses supply these fields. Only fixed assignments containing
# shlex.quote'd strings reach eval; the record itself is never evaluated.
sid=""
cwd=""
transcript=""
parsed=0
if command -v python3 >/dev/null 2>&1; then
  eval "$(printf '%s' "$payload" | python3 -c '
import json, sys, shlex
print("parsed=1", flush=True)
try:
    d = json.loads(sys.stdin.buffer.read().decode("utf-8"))
except Exception:
    sys.exit(0)
if not isinstance(d, dict) or d.get("hook_event_name", "SessionStart") != "SessionStart":
    sys.exit(0)
if "cwd" in d and not isinstance(d["cwd"], str):
    sys.exit(0)
def s(k):
    v = d.get(k, "")
    return v if isinstance(v, str) else ""
sid, cwd, transcript = s("session_id"), s("cwd"), s("transcript_path")
# Shell command substitution can discard NUL before the shell-side checks.
if "\0" in sid or "\0" in cwd:
    sys.exit(0)
if "\0" in transcript:
    transcript = ""
try:
    sid.encode("utf-8")
    cwd.encode("utf-8")
except UnicodeError:
    sys.exit(0)
try:
    transcript.encode("utf-8")
except UnicodeError:
    transcript = ""
assignments = "\n".join(("sid=" + shlex.quote(sid),
                        "cwd=" + shlex.quote(cwd),
                        "transcript=" + shlex.quote(transcript)))
sys.stdout.buffer.write((assignments + "\n").encode("utf-8"))
' 2>/dev/null)"
fi

# Fallback for missing/broken python3. Current SessionStart inputs are flat
# objects. Validate that whole shape and its required field types; reject
# nested values, duplicate/escaped keys, or escaped identity/cwd strings.
# No unescaping or eval: unsupported input must leave an existing binding
# intact rather than guessing which JSON key or truncated string was intended.
_fallback_json_string() {
  printf '%s' "$payload" | LC_ALL=C awk -v wanted="$1" '
function space() {
    while (p <= n && index(" \t\r\n", substr(json, p, 1))) p++
}
function string(    start, c, e, hex) {
    if (substr(json, p++, 1) != "\"") { bad = 1; return "" }
    start = p
    while (p <= n) {
        c = substr(json, p++, 1)
        if (c == "\"") return substr(json, start, p - start - 1)
        if (c ~ /[[:cntrl:]]/) { bad = 1; return "" }
        if (c == "\\") {
            if (p > n) { bad = 1; return "" }
            e = substr(json, p++, 1)
            if (e == "u") {
                hex = substr(json, p, 4)
                if (length(hex) != 4 || hex ~ /[^0-9a-fA-F]/) {
                    bad = 1; return ""
                }
                p += 4
            } else if (!index("\"\\/bfnrt", e)) {
                bad = 1; return ""
            }
        }
    }
    bad = 1
    return ""
}
{ json = json $0 "\n" }
END {
    p = 1; n = length(json)
    # Byte-level UTF-8 validation in C locale: exclude overlong sequences,
    # surrogate encodings, and code points beyond U+10FFFF.
    if (n > 65536 || json !~ /^([\001-\177]|[\302-\337][\200-\277]|\340[\240-\277][\200-\277]|[\341-\354\356-\357][\200-\277][\200-\277]|\355[\200-\237][\200-\277]|\360[\220-\277][\200-\277][\200-\277]|[\361-\363][\200-\277][\200-\277][\200-\277]|\364[\200-\217][\200-\277][\200-\277])*$/) exit 1
    space()
    if (substr(json, p++, 1) != "{") exit 1
    space()
    if (substr(json, p, 1) == "}") {
        p++
    } else {
        while (p <= n) {
            key = string()
            if (bad || index(key, "\\") || seen[key]++) exit 1
            space()
            if (substr(json, p++, 1) != ":") exit 1
            space()
            if (substr(json, p, 1) == "\"") {
                values[key] = string(); kinds[key] = "string"
                if (bad) exit 1
            } else {
                rest = substr(json, p)
                if (!match(rest, /^(-?(0|[1-9][0-9]*)([.][0-9]+)?([eE][+-]?[0-9]+)?|true|false|null)/)) exit 1
                p += RLENGTH; kinds[key] = "other"
            }
            space()
            c = substr(json, p++, 1)
            if (c == "}") break
            if (c != ",") exit 1
            space()
        }
        if (c != "}") exit 1
    }
    space()
    if (p <= n || kinds["session_id"] != "string") exit 1
    if (("cwd" in kinds) && kinds["cwd"] != "string") exit 1
    if (("hook_event_name" in kinds) &&
        (kinds["hook_event_name"] != "string" || values["hook_event_name"] != "SessionStart")) exit 1
    if (index(values["session_id"], "\\") || index(values["cwd"], "\\")) exit 1
    if (wanted == "transcript_path" && index(values[wanted], "\\")) exit 0
    printf "%s", values[wanted]
}' 2>/dev/null
}
if [ "$parsed" != 1 ]; then
  event="$(_fallback_json_string hook_event_name)"
  case "$event" in
    ""|SessionStart) ;;
    *) exit 0 ;;
  esac
  sid="$(_fallback_json_string session_id)"
  cwd="$(_fallback_json_string cwd)"
  transcript="$(_fallback_json_string transcript_path)"
fi

[ -n "$sid" ] || exit 0
[ -n "$cwd" ] || cwd="$PWD"

# session_id must look like a session id and nothing else -- this string is
# later passed to a resume command, so it must not be able to carry shell
# metacharacters or extra flags.
case "$sid" in
  -*)               exit 0 ;;
  *[!0-9a-zA-Z_-]*) exit 0 ;;
esac
[ "${#sid}" -le 64 ] || exit 0
# Codex also accepts thread names; use UUIDs only so a recorded identity cannot
# accidentally resolve a different thread after a rename.
if [ "$harness" = codex-cli ]; then
  case "$sid" in
    ????????-????-????-????-????????????) ;;
    *) exit 0 ;;
  esac
  hex="$(printf '%s' "$sid" | tr -d '-')"
  case "$hex" in
    *[!0-9a-fA-F]*) exit 0 ;;
  esac
  [ "${#hex}" -eq 32 ] || exit 0
fi

# cwd is written into a TAB-delimited record and later displayed. A tab or
# newline would split the record into bogus fields; other control characters
# are terminal escapes. Drop the record rather than write a corrupt one.
# [[:cntrl:]] is locale-dependent: under a UTF-8 locale (what Warp and Claude
# Code run) it also catches C1 controls and, on macOS, Unicode bidi overrides.
# Under LANG=C only ASCII controls are caught; the zsh side re-checks anyway.
case "$cwd" in
  *[[:cntrl:]]*) exit 0 ;;
  /*) ;;
  *) exit 0 ;;
esac

# Details are optional. Omit an unusable path without losing the pane binding.
# The reader additionally confines it to the configured transcript root.
case "$transcript" in
  *[[:cntrl:]]*) transcript="" ;;
  /*)
    case "$harness:$transcript" in
      claude-code:*/"$sid".jsonl|codex-cli:*/rollout-*-"$sid".jsonl) ;;
      *) transcript="" ;;
    esac
    ;;
  *) transcript="" ;;
esac

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
chmod 700 "$STATE_DIR" 2>/dev/null

# One record per pane. A new session in the same pane (including after /clear)
# overwrites it, so a pane always reattaches to whatever it last had.
# umask 077 so the temp file is born 0600; the chmod after is belt-and-braces.
# mkdir above runs before the umask on purpose: a 0700 dir is what we want,
# and chmod 700 pins it even if the dir pre-existed with looser permissions.
tmp="${STATE_DIR}/.${pane}.tmp.$$"
umask 077
if printf '%s\t%s\t%s\t%s\t%s\n' "$harness" "$sid" "$cwd" "$(date +%s)" "$transcript" > "$tmp" 2>/dev/null; then
  chmod 600 "$tmp" 2>/dev/null
  mv -f "$tmp" "${STATE_DIR}/${pane}" 2>/dev/null
fi
rm -f "$tmp" 2>/dev/null

# Deliberately no cleanup of old records. Records are ~100 bytes, one per pane
# UUID; nothing reads a stale one (the zsh side ignores records older than
# WARP_RESUME_MAX_AGE). A prune existed and was removed: STATE_DIR is
# user-settable, and any `find -delete` under a user-chosen path is a way to
# lose real files. `rm -rf ~/.warp-resume/panes` is the manual reset.

exit 0
