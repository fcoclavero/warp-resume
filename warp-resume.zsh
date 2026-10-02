# ---------------------------------------------------------------------------
# Warp: reattach a restored pane to its own Claude Code or Codex CLI session.
#
# Source this from ~/.zshrc:
#     WARP_RESUME_CLAUDE_FLAGS=(--permission-mode bypassPermissions)   # optional
#     source ~/.warp-resume/warp-resume.zsh
#
# How it tells a restored pane from a new one:
#   - Warp exports $WARP_TERMINAL_SESSION_UUID into every local pane.
#   - A RESTORED pane comes back with the UUID it had before the restart, so a
#     record written by the SessionStart hook already exists for it.
#   - A BRAND NEW pane gets a freshly generated random UUID, so no record
#     exists and this does nothing at all.
#
# Nothing runs during .zshrc itself. The check is deferred to a one-shot
# precmd hook, so a prompt framework (powerlevel10k's instant prompt in
# particular, which redirects stdio during init) finishes first, and a Ctrl-C
# at the prompt can't abort the rest of your .zshrc.
#
# Knobs (set BEFORE the source line):
#   WARP_RESUME_CLAUDE_FLAGS
#         zsh ARRAY of flags always passed on resume. Mirror your own launch
#         alias here, e.g.
#             WARP_RESUME_CLAUDE_FLAGS=(--permission-mode bypassPermissions)
#         Must be an array. A plain string is rejected with a warning.
#   WARP_RESUME_CODEX_FLAGS
#         zsh ARRAY of flags passed to `codex resume`. --no-daemon is always
#         added: a shared server cannot inherit each client's pane UUID.
#   WARP_RESUME_MAX_AGE   seconds; ignore records older than this. Default 7d.
#   WARP_RESUME_AUTO      1 = resume without asking. Default 0 (prompt).
#   WARP_RESUME_DISABLE   1 = disable automatic startup offers.
#   WARP_RESUME_DETAILS   1 = under the prompt, show the session's title,
#         when it was last used, its size and your last message, read from
#         the harness's own transcript. Default 1. 0 = id and path only.
#   WARP_RESUME_CLAUDE_TRANSCRIPT_DIR   where Claude Code keeps transcripts.
#         Default ${CLAUDE_CONFIG_DIR:-~/.claude}/projects.
#   WARP_RESUME_CODEX_TRANSCRIPT_DIR   where Codex CLI keeps transcripts.
#         Default ${CODEX_HOME:-~/.codex}/sessions.
#   WARP_RESUME_CODEX_INDEX   Codex's append-only thread-name index.
#         Default ${CODEX_HOME:-~/.codex}/session_index.jsonl.
# ---------------------------------------------------------------------------

# Exported so the SessionStart hook writes where this reads. Without the
# export the two halves can silently disagree.
# Quoted: under GLOB_SUBST (set shell-wide by `emulate sh`) an unquoted
# default containing [ would be globbed and abort the source.
: "${WARP_RESUME_STATE_DIR:=$HOME/.warp-resume/panes}"
export WARP_RESUME_STATE_DIR
: ${WARP_RESUME_MAX_AGE:=604800}
: ${WARP_RESUME_AUTO:=0}
: ${WARP_RESUME_DISABLE:=0}
: ${WARP_RESUME_DETAILS:=1}
: "${WARP_RESUME_CLAUDE_TRANSCRIPT_DIR:=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects}"
: "${WARP_RESUME_CODEX_TRANSCRIPT_DIR:=${CODEX_HOME:-$HOME/.codex}/sessions}"
: "${WARP_RESUME_CODEX_INDEX:=${CODEX_HOME:-$HOME/.codex}/session_index.jsonl}"

# Accept an array; reject a scalar loudly rather than silently discarding it,
# which is what `typeset -ga` alone would do to a string containing flags.
# An anonymous function keeps its loop variable and options out of .zshrc.
() {
  emulate -L zsh
  local var
  for var in WARP_RESUME_CLAUDE_FLAGS WARP_RESUME_CODEX_FLAGS; do
    [[ ${(tP)var} == array* ]] && continue
    if [[ -n ${(P)var} ]]; then
      print -u2 -- "warp-resume: $var must be an array, e.g. $var=(--flag value)"
      print -u2 -- "             ignoring the string value you set."
    fi
    unset "$var"
    typeset -ga "$var"
  done
}

# Manually reattach the current pane, ignoring the age limit. Handy if you
# said "no" at the prompt and changed your mind.
warp-resume() { _warp_resume_reattach force; }

# Show what's recorded for every pane.
warp-resume-list() {
  emulate -L zsh
  setopt localoptions no_nomatch
  local f harness sid cwd ts transcript found=0
  [[ -d $WARP_RESUME_STATE_DIR ]] || { print -- "no records"; return 0; }
  for f in $WARP_RESUME_STATE_DIR/*; do
    [[ -f $f && -r $f ]] || continue
    found=1
    IFS=$'\t' read -r harness sid cwd ts transcript < "$f"
    # (V): show control characters visibly. A tampered record must not be able
    # to put terminal escapes on screen via a diagnostic command.
    printf '%s  %-11s %-40s %s\n' "${(V)${${f:t}:0:8}}" "${(V)harness}" "${(V)sid}" "${(V)cwd}"
  done
  (( found )) || print -- "no records"
}
_warp_resume_valid_session() {
  emulate -L zsh
  local harness=${1:-} sid=${2:-} hex
  [[ -n $sid && -z ${sid//[0-9a-zA-Z_-]/} && ${#sid} -le 64 && $sid != -* ]] || return 1
  case $harness in
    claude-code) ;;
    codex-cli)
      hex=${sid//-/}
      [[ $sid == ????????-????-????-????-???????????? \
          && ${#hex} == 32 && -z ${hex//[0-9a-fA-F]/} ]] || return 1
      ;;
    *) return 1 ;;
  esac
  return 0
}

# Forget this pane's binding, so it stops offering to resume.
warp-resume-forget() {
  emulate -L zsh
  local pane=${WARP_TERMINAL_SESSION_UUID:-}
  [[ -n $pane && -z ${pane//[0-9a-fA-F]/} && ${#pane} -le 64 ]] || { print -- "not a Warp pane"; return 1; }
  rm -f -- "$WARP_RESUME_STATE_DIR/$pane" && print -- "forgotten"
}

# Print what a session was about, under the resume prompt:
#     "Draft methods section" · 2d ago · 3.1 MB · 41 prompts
#     last: can you tighten the county comparison table…
# Everything shown comes from the transcript, which is UNTRUSTED text (it holds
# pasted content, tool output, anything). python3 strips every control/format
# character and the field separator before zsh sees it; zsh then prints it
# with print -r and (V) only, never through print -P. An absent or unreadable
# transcript prints nothing; without python3 only age and size are shown.
# Details are a convenience and must never block or clutter the prompt.
_warp_resume_details() {
  emulate -L zsh
  setopt localoptions no_nomatch
  zmodload -F zsh/datetime +p:EPOCHSECONDS 2>/dev/null
  local harness=${1:-} sid=${2:-} recorded=${3:-} dir pat f= index=
  # Re-check: this function is callable on its own, and sid becomes a pattern.
  _warp_resume_valid_session "$harness" "$sid" || return 0
  case $harness in
    claude-code)
      dir=$WARP_RESUME_CLAUDE_TRANSCRIPT_DIR
      pat="${(b)dir}/*/${sid}.jsonl(N.om)"
      ;;
    codex-cli)
      dir=$WARP_RESUME_CODEX_TRANSCRIPT_DIR
      pat="${(b)dir}/*/*/*/rollout-*-${sid}.jsonl(N.om)"
      [[ $WARP_RESUME_CODEX_INDEX == /* \
          && -f $WARP_RESUME_CODEX_INDEX && -r $WARP_RESUME_CODEX_INDEX ]] \
        && index=$WARP_RESUME_CODEX_INDEX
      ;;
  esac
  [[ $dir == /* && -d $dir ]] || return 0
  local root=${dir:P} candidate
  root=${root%/}
  # A tampered record must not turn details into an arbitrary-file reader.
  # :P resolves components physically, in order. :A collapses ".." before
  # following symlinks, which can validate a different file than open reads.
  # Read the validated physical pathname, including for stow-managed roots.
  if [[ $recorded == /* && $recorded != *[[:cntrl:]]* \
        && -f $recorded && -r $recorded ]]; then
    candidate=${recorded:P}
    if [[ $candidate == $root/* ]]; then
      case $harness in
        claude-code) [[ ${candidate:t} == ${sid}.jsonl ]] && f=$candidate ;;
        codex-cli) [[ ${candidate:t} == rollout-*-${sid}.jsonl ]] && f=$candidate ;;
      esac
    fi
  fi

  # $dir is not glob-substituted (emulate zsh), so only the * is a pattern.
  # Newest first if the same id somehow exists in two project folders.
  # Built as a string and expanded with ${~...}: a literal (N.om) qualifier
  # is a parse error when this file is sourced under `emulate sh`. (b) quotes
  # any pattern characters in $dir, so only the * and the qualifier are live.
  local -a files
  if [[ -z $f ]]; then
    files=( ${~pat} )
    for f in "${files[@]}"; do
      candidate=${f:P}
      if [[ -f $candidate && -r $candidate && $candidate == $root/* ]]; then
        f=$candidate
        break
      fi
      f=
    done
  fi
  [[ -n $f ]] || return 0

  # mtime + size from zsh itself, so "last used" works even without python3.
  # zstat takes only one +element per call, so fetch the whole hash.
  local -A st
  zmodload -F zsh/stat b:zstat 2>/dev/null
  zstat -H st -- $f 2>/dev/null || st=()

  local ago= size=
  if [[ ${st[mtime]-} == <-> && ${st[size]-} == <-> ]]; then
    local now=${EPOCHSECONDS:-$(date +%s)} d
    (( d = now - st[mtime] )); (( d < 0 )) && d=0
    if   (( d < 60 ));      then ago="just now"
    elif (( d < 3600 ));    then ago="$(( d / 60 ))m ago"
    elif (( d < 86400 ));   then ago="$(( d / 3600 ))h ago"
    elif (( d < 1209600 )); then ago="$(( d / 86400 ))d ago"
    else                         ago="$(( d / 604800 ))w ago"
    fi
    if (( st[size] < 1048576 )); then size="$(( (st[size] + 1023) / 1024 )) KB"
    else size=$(LC_ALL=C printf '%.1f MB' $(( st[size] / 1048576.0 ))); fi
  fi

  # title, first prompt, last prompt, prompt count; joined by \x1f, which the
  # python side guarantees cannot occur inside a field. \x1f is not IFS
  # whitespace, so empty fields survive the split (a tab separator would
  # collapse them).
  local raw= title= first= last= count=
  local py=${commands[python3]:-}
  if [[ $py == /* && -x $py ]]; then
    raw=$("$py" - "$harness" "$f" "$sid" "$index" 2>/dev/null <<'PY'
import sys, json, unicodedata
from collections import Counter
def rows(path, needles):
    with open(path, "rb") as fh:
        for raw in fh:
            # Most lines are assistant/tool traffic.
            if not any(needle in raw for needle in needles):
                continue
            try:
                row = json.loads(raw)
            except (ValueError, UnicodeError):
                continue
            if isinstance(row, dict):
                yield row

def clean(s, n):
    # Drop every Unicode control/format/private/unassigned char (Cc Cf Co Cn
    # Cs): terminal escapes, bidi overrides, zero-width tricks. Whitespace
    # runs (incl. newlines) collapse to one space.
    out = []
    for ch in s:
        if ch.isspace():
            out.append(" ")
        elif unicodedata.category(ch)[0] != "C":
            out.append(ch)
    s = " ".join("".join(out).split())
    return s if len(s) <= n else s[: n - 1].rstrip() + "…"

def text_of(msg, sep=" "):
    c = msg.get("content") if isinstance(msg, dict) else None
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        parts = []
        for it in c:
            if not isinstance(it, dict):
                continue
            if it.get("type") == "tool_result":
                return ""          # a tool result, not something you typed
            if it.get("type") == "text" and isinstance(it.get("text"), str):
                parts.append(it["text"])
        return sep.join(parts)
    return ""

def typed(t):
    t = t.strip()
    if not t:
        return False
    # Slash commands, their output, hook/system injections, interrupts.
    if t.startswith(("<", "Caveat:", "[Request interrupted")):
        return False
    return True

def claude_details(path):
    title = summary = first = last = ""
    count = 0
    for d in rows(path, (b'"user"', b'itle"', b'"summary"')):
        ty = d.get("type")
        if isinstance(ty, str) and ty.endswith("title"):
            for k in ("customTitle", "aiTitle", "title"):
                v = d.get(k)
                if isinstance(v, str) and v.strip():
                    # /rename (custom) beats a generated title; latest wins.
                    if k == "customTitle" or not title.startswith("\0c"):
                        title = ("\0c" if k == "customTitle" else "") + v
                    break
        elif ty == "summary" and isinstance(d.get("summary"), str):
            summary = d["summary"]
        elif ty == "user":
            if d.get("isMeta") or d.get("isSidechain") or d.get("isCompactSummary"):
                continue
            t = text_of(d.get("message"))
            if typed(t):
                count += 1
                if not first:
                    first = t
                last = t
    title = title[2:] if title.startswith("\0c") else title
    return title or summary or first, first, last, count

def codex_details(path, sid, index):
    title = ""
    if index:
        try:
            for d in rows(index, (b'"thread_name"',)):
                if d.get("id") == sid and isinstance(d.get("thread_name"), str):
                    title = d["thread_name"].strip()
        except OSError:
            pass
    first = last = ""
    count = 0
    unmatched = {"modern": Counter(), "legacy": Counter()}
    seen = set()
    for d in rows(path, (b'"UserMessage"', b'"user_message"')):
        payload = d.get("payload")
        if d.get("type") != "event_msg" or not isinstance(payload, dict):
            continue
        if payload.get("type") == "item_completed":
            item = payload.get("item")
            if not isinstance(item, dict) or item.get("type") != "UserMessage":
                continue
            item_id = item.get("id")
            if isinstance(item_id, str) and item_id:
                if item_id in seen:
                    continue
                seen.add(item_id)
            t = text_of(item, "")
            client_id = item.get("client_id")
            kind, other = "modern", "legacy"
        elif payload.get("type") == "user_message":
            t = payload.get("message")
            if not isinstance(t, str):
                continue
            client_id = payload.get("client_id")
            kind, other = "legacy", "modern"
        else:
            continue
        if not typed(t):
            continue
        # Durable history normally stores only one view, but a format change
        # can leave both generations in one file. Retain every unmatched
        # occurrence. Imported double views can be paired by client_id only,
        # one-to-one: matching text or a shared turn cannot prove duplication.
        if isinstance(client_id, str) and client_id:
            if unmatched[other][client_id]:
                unmatched[other][client_id] -= 1
                if not unmatched[other][client_id]:
                    del unmatched[other][client_id]
                continue
            unmatched[kind][client_id] += 1
        count += 1
        if not first:
            first = t
        last = t
    return title or first, first, last, count

try:
    harness, path, sid, index = sys.argv[1:]
    if harness == "claude-code":
        shown, first, last, count = claude_details(path)
    else:
        shown, first, last, count = codex_details(path, sid, index)
except Exception:
    # Details are best-effort, including files changing while being read.
    sys.exit(0)
fields = [clean(shown, 72), clean(first, 90), clean(last, 90), str(count)]
sys.stdout.write("\x1f".join(f.replace("\x1f", " ") for f in fields))
PY
)
    local -a parts
    local sep=$'\x1f'
    parts=( "${(@ps:$sep:)raw}" )
    if (( ${#parts} == 4 )); then
      title=$parts[1] first=$parts[2] last=$parts[3] count=$parts[4]
      [[ $count == <-> ]] || count=
    fi
  fi

  [[ -n $title || -n $ago ]] || return 0

  # Line 1: title · age · size · prompts. Colours via -P on constant strings
  # only; data via -r with (V) as a second guard.
  local -a meta
  [[ -n $ago ]] && meta+=( $ago )
  [[ -n $size ]] && meta+=( $size )
  [[ -n $count && $count != 0 ]] && meta+=( "$count prompt${${count:#1}:+s}" )
  print -rn -- "  "
  if [[ -n $title ]]; then
    print -Pn "%B"; print -rn -- "${(V)title}"; print -Pn "%b"
    (( ${#meta} )) && print -rn -- "  "
  fi
  print -Pn "%F{8}"; print -rn -- "${(j: · :)meta}"; print -Pn "%f"
  print

  # Line 2: the last thing you typed, if it adds anything over the title.
  if [[ -n $last && $last != $title ]]; then
    print -Pn "  %F{8}last:%f "; print -r -- "${(V)last}"
  fi
  return 0
}

_warp_resume_reattach() {
  # Local option scope: correct under nounset, ksh_arrays, sh_word_split etc.
  emulate -L zsh
  zmodload -F zsh/datetime +p:EPOCHSECONDS 2>/dev/null
  local force=${1:-}

  # Guard against a nested shell inside a resumed session (exported), and
  # against this file being sourced twice in one shell (shell-scoped).
  [[ -z ${WARP_RESUME_ACTIVE:-}${SSH_CONNECTION:-}${SSH_TTY:-} ]] || return 0

  local pane=${WARP_TERMINAL_SESSION_UUID:-}
  [[ -n $pane && -z ${pane//[0-9a-fA-F]/} && ${#pane} -le 64 ]] || return 0

  local rec="$WARP_RESUME_STATE_DIR/$pane"
  # -r as well as -f: an unreadable record must not print an error on every
  # shell start. Silence is the contract for anything we can't use.
  [[ -f $rec && -r $rec ]] || return 0

  local line trailing= sep=$'\t'
  local -a fields
  {
    IFS= read -r line || return 0
    # A second line, even blank or unterminated, is not a single pane record.
    IFS= read -r trailing && return 0
    [[ -z $trailing ]] || return 0
  } < "$rec" 2>/dev/null || return 0
  # Preserve empty fields, including the optional trailing transcript path.
  # IFS whitespace splitting would collapse them and accept malformed rows.
  fields=( "${(@ps:$sep:)line}" )
  (( ${#fields} == 5 )) || return 0
  local harness=$fields[1] sid=$fields[2] cwd=$fields[3] ts=$fields[4] transcript=$fields[5]

  # The record is local, but it is still input: $sid reaches a command line
  # and $cwd reaches your terminal and `cd`.
  _warp_resume_valid_session "$harness" "$sid" || return 0
  [[ $cwd == /* && $cwd != *[[:cntrl:]]* ]] || return 0
  # <-> alone accepts any digit run; zsh arithmetic warns past 19 digits.
  [[ $ts == <-> && ${#ts} -le 12 ]] || return 0
  [[ -z $transcript || ( $transcript == /* && $transcript != *[[:cntrl:]]* ) ]] || return 0

  local now=$EPOCHSECONDS
  [[ -n $now ]] || now=$(date +%s)
  if [[ $force != force ]]; then
    (( now - ts < WARP_RESUME_MAX_AGE )) || return 0
  fi

  # Only this allowlisted adapter dispatch supplies executables and arguments.
  # Flags are your standing choice, never values copied from a record.
  local name shown_mode="" fresh i
  local -a extra_args resume_args
  case $harness in
    claude-code)
      name=claude
      extra_args=("${WARP_RESUME_CLAUDE_FLAGS[@]}")
      resume_args=("${extra_args[@]}" --resume "$sid")
      fresh=claude
      # Keep the original permission-mode display, including --mode=value.
      i=${extra_args[(I)--permission-mode]}
      if (( i )); then
        shown_mode="${extra_args[i+1]-}"
      else
        i=${extra_args[(I)--permission-mode=*]}
        (( i )) && shown_mode="${${extra_args[i]-}#--permission-mode=}"
      fi
      ;;
    codex-cli)
      name=codex
      extra_args=(--no-daemon "${WARP_RESUME_CODEX_FLAGS[@]}")
      resume_args=(resume "${extra_args[@]}" "$sid")
      shown_mode="${(j: :)extra_args}"
      fresh="codex --no-daemon"
      ;;
  esac

  [[ -d $cwd ]] || {
    print -Pn "%F{3}warp-resume:%f recorded directory is gone: "
    print -r -- "$cwd"
    return 0
  }

  if [[ $WARP_RESUME_AUTO != 1 ]]; then
    # No controlling terminal means no way to ask. Fail closed, but say so --
    # a silent no-op here is indistinguishable from "not installed".
    if [[ ! -t 0 || ! -t 1 ]]; then
      print -u2 -- "warp-resume: no terminal to prompt on; run 'warp-resume' to reattach."
      return 0
    fi

    # Display the path with $HOME abbreviated only on a component boundary,
    # so /Users/bobby does not render as ~by.
    local disp=$cwd
    if [[ $cwd == $HOME || $cwd == $HOME/* ]]; then disp="~${cwd#$HOME}"; fi

    # Colour codes go through prompt expansion; the DATA does not -- print -P
    # on an untrusted path would expand %-escapes and, under PROMPT_SUBST,
    # execute $(...) inside it.
    # $sid goes through -P; that is safe only because of the charset check
    # above (no %, no $, no backslash can be in it). $disp never goes through -P.
    print -Pn "%F{6}${name}%f %F{3}${sid[1,8]}%f  %F{8}"
    print -rn -- "$disp"
    print -Pn "%f"
    if [[ -n $shown_mode ]]; then
      print -Pn "  %F{8}"
      print -rn -- "${(V)shown_mode}"
      print -Pn "%f"
    fi
    print

    # Title, age and last message, so you can tell panes apart. Best effort.
    [[ $WARP_RESUME_DETAILS == 1 ]] && _warp_resume_details "$harness" "$sid" "$transcript"

    local ans
    printf 'resume? [Y/n] '
    read -r ans || { print; return 0; }
    [[ $ans == [nN]* ]] && return 0
  fi

  # Resolve the binary BEFORE changing directory, to an absolute path, and
  # call that path: a bare harness command would be (a) alias-expanded at source
  # time, silently baking in flags the consent prompt never showed, and
  # (b) PATH-resolved after the cd, so with `.` in PATH a record could steer
  # the shell into a directory containing its own executable. Same reason for
  # `builtin cd`: a cd alias/function (zoxide etc.) must not intercept this.
  # $commands ignores relative/empty PATH entries, so the /* check is a second
  # layer, not the only one. Claude Code's local installer may define claude
  # only as `alias claude=/abs/path`; honour exactly that shape (an absolute
  # path with no spaces, i.e. no flags), nothing else. -x: a stale hash entry
  # must fail silently, not print "no such file" on every restore.
  local bin=${commands[$name]:-}
  if [[ $bin != /* ]]; then
    bin=${aliases[$name]:-}
    [[ $bin == /* && $bin != *[[:space:]]* ]] || bin=
  fi
  [[ -n $bin && -x $bin ]] || {
    print -u2 -- "warp-resume: $name not found in PATH"
    return 0
  }

  # Only move the shell once you've agreed to resume.
  builtin cd -- "$cwd" || {
    print -Pn "%F{1}warp-resume:%f could not enter "
    print -r -- "$cwd"
    return 0
  }

  local rc=0
  WARP_RESUME_ACTIVE=1 "$bin" "${resume_args[@]}" || rc=$?
  # 130 is Ctrl-C, 1 is often a normal quit. Only a clear failure to start is
  # worth commenting on, and even then don't assert why.
  if (( rc != 0 && rc != 130 && rc != 1 )); then
    print -Pn "%F{1}warp-resume:%f ${name} exited ${rc} resuming ${sid[1,8]}."
    print
    print -P "%F{8}run '${fresh}' for a fresh session, or 'warp-resume-forget' to stop offering.%f"
  fi
}

# Defer the check to just before the first prompt, then unregister. Running
# during .zshrc breaks powerlevel10k's instant prompt (stdio is redirected
# there, so the tty test fails and this would silently never fire) and would
# let a Ctrl-C at the prompt abort the rest of your .zshrc.
_warp_resume_precmd() {
  add-zsh-hook -d precmd _warp_resume_precmd 2>/dev/null
  unfunction _warp_resume_precmd 2>/dev/null
  _warp_resume_reattach
}

if [[ $WARP_RESUME_DISABLE != 1 && -o interactive \
      && -n ${WARP_TERMINAL_SESSION_UUID:-} && -z ${WARP_RESUME_ACTIVE:-} \
      && -z ${SSH_CONNECTION:-}${SSH_TTY:-} \
      && -z ${WARP_RESUME_RAN:-} ]]; then
  typeset -g WARP_RESUME_RAN=1          # shell-scoped: survives a second source
  autoload -Uz add-zsh-hook
  add-zsh-hook precmd _warp_resume_precmd
fi
