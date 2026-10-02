# warp-resume

Bring each restored Warp pane back to **its own Claude Code or Codex CLI conversation**, not the newest session in its directory. Two panes in the same repository keep separate session identities.

A faithful port of [warp-claude-resume](https://github.com/supersistence/warp-claude-resume): two runtime shell scripts, no build step, and the same confirmation prompt, auto mode, age limit, and manual controls. Python 3 is optional at runtime.

## How it works

1. Each selected harness runs `record-session.sh` from its `SessionStart` hook, passing `claude-code` or `codex-cli`.
1. The hook atomically writes a private record in `~/.warp-resume/panes/<pane-uuid>`, keyed by `WARP_TERMINAL_SESSION_UUID`.
1. A one-shot zsh `precmd` hook offers to resume that pane's recorded harness and exact session ID after `.zshrc` finishes.

Claude resumes with `claude --resume <id>`. Codex resumes with `codex resume --no-daemon <id>`. Configured flags are passed separately for each harness.

New panes and non-Warp shells have no matching record. SSH shells are skipped. Starting another session, including switching harnesses in the same pane, replaces its binding. Only sessions started or resumed after installing the hook are tracked.

## Requirements

- Warp with **Settings > Features > Restore windows, tabs, and panes on startup** enabled.
- zsh. bash and fish startup integration is not supported.
- Claude Code with `SessionStart` hooks, Codex CLI with `SessionStart` hooks and `--no-daemon`, or both.
- Standard POSIX shell utilities. Python 3 adds transcript titles, message counts, and last-message details; without it, age and size still work.

Researched against Claude Code **2.1.287** and Codex CLI **0.159.3**. Regression and PTY tests run on macOS with zsh 5.9.2. Linux and WSL have not been validated for this port.

## Install

From this directory:

```sh
bash test.sh
mkdir -p "$HOME/.warp-resume"
cp record-session.sh warp-resume.zsh "$HOME/.warp-resume/"
chmod +x "$HOME/.warp-resume/record-session.sh"
```

The tests require working Python 3 for fixtures. They use a temporary HOME/ZDOTDIR and stub CLIs, not your installed harnesses or real configuration.

Install the hook for either harness or both. **Merge into existing configuration; do not overwrite other keys or hooks.**

### Claude Code

Add this handler to `${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"$HOME/.warp-resume/record-session.sh\" claude-code"
          }
        ]
      }
    ]
  }
}
```

No `SubagentStart` hook is needed. See the [Claude Code hook reference](https://code.claude.com/docs/en/hooks).

### Codex CLI

Add this handler to `${CODEX_HOME:-~/.codex}/hooks.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"$HOME/.warp-resume/record-session.sh\" codex-cli"
          }
        ]
      }
    ]
  }
}
```

If you already keep hooks inline in `config.toml`, merge the equivalent there instead:

```toml
[[hooks.SessionStart]]

[[hooks.SessionStart.hooks]]
type = "command"
command = '"$HOME/.warp-resume/record-session.sh" codex-cli'
```

Use one representation for this hook, not both. Codex merges matching hook sources rather than replacing them.

Launch Codex with:

```sh
codex --no-daemon
```

Open `/hooks` inside Codex and review and trust the new handler. New or changed hook definitions are skipped until trusted; hooks must also be enabled in your configuration.

**Every tracked Codex launch must use `--no-daemon`, including initial launches.** Codex hooks inherit their server process's environment. A shared daemon can retain another pane's UUID; a dedicated local server inherits the calling pane's UUID. This port always adds `--no-daemon` on resume but does not wrap or intercept normal `codex` commands. Shared-daemon and remote Codex sessions are unsupported.

**Codex records on the first submitted turn, not just when its TUI opens.** A newly opened session is not bound until then. The same timing applies to refreshing a resumed session's record. See the [Codex hook reference](https://developers.openai.com/codex/hooks).

### zsh

Add this to `.zshrc`, after your prompt framework and PATH setup:

```zsh
source "$HOME/.warp-resume/warp-resume.zsh"
```

Optional settings go **before** the source line:

```zsh
# Mirror your standing launch options, deliberately:
# WARP_RESUME_CLAUDE_FLAGS=(--permission-mode plan)
# WARP_RESUME_CODEX_FLAGS=(--sandbox read-only)
# WARP_RESUME_AUTO=1
source "$HOME/.warp-resume/warp-resume.zsh"
```

Flags must be zsh arrays. A plain string is rejected with a warning and ignored. Aliases carrying flags are deliberately bypassed, so configure the flags you want restored explicitly. Bare absolute-path aliases are supported.

If using custom `CLAUDE_CONFIG_DIR` or `CODEX_HOME`, export them before launching the CLI and before sourcing the library.

### Switching from warp-claude-resume

Replace the old source line and Claude hook with the new ones; do not leave both integrations enabled. Rename the settings:

- `WARP_CLAUDE_RESUME_FLAGS` becomes `WARP_RESUME_CLAUDE_FLAGS`.
- `WARP_CLAUDE_TRANSCRIPT_DIR` becomes `WARP_RESUME_CLAUDE_TRANSCRIPT_DIR`.
- Other `WARP_CLAUDE_*` controls become `WARP_RESUME_*`.

Keep the new default state directory. Old four-column records are not migrated or accepted. Start or resume each conversation in its intended pane to populate the new records. Old scripts, records, and conversations are not automatically modified or removed.

## Using it

A restored Codex pane might show:

```text
codex 01a0643a  ~/src/my_app  --no-daemon --sandbox read-only
  Plan Node.js upgrade  2d ago · 3.1 MB · 41 prompts
  last: add a test for the expired-token path
resume? [Y/n]
```

Enter accepts. `n` declines without changing directory. Claude shows the same layout with `claude` and its configured permission mode, if any. `WARP_RESUME_AUTO=1` skips confirmation.

Shell commands:

- `warp-resume`: resume this pane now, ignoring the age limit. Still prompts unless auto mode is enabled.
- `warp-resume-list`: list every recorded pane, harness, session ID, and directory.
- `warp-resume-forget`: remove only this pane's binding.

Settings, set before sourcing:

- `WARP_RESUME_CLAUDE_FLAGS=()`: flags for `claude --resume`.
- `WARP_RESUME_CODEX_FLAGS=()`: flags for `codex resume`; `--no-daemon` is always added.
- `WARP_RESUME_AUTO=0`: `1` resumes without asking.
- `WARP_RESUME_MAX_AGE=604800`: seconds since the record's latest `SessionStart`, default seven days. Controls offering, not transcript retention.
- `WARP_RESUME_DISABLE=0`: `1` disables automatic startup offers.
- `WARP_RESUME_DETAILS=1`: `0` hides transcript details.
- `WARP_RESUME_STATE_DIR=~/.warp-resume/panes`: record location, exported to hook processes and never pruned.
- `WARP_RESUME_CLAUDE_TRANSCRIPT_DIR=${CLAUDE_CONFIG_DIR:-~/.claude}/projects`: Claude transcript root.
- `WARP_RESUME_CODEX_TRANSCRIPT_DIR=${CODEX_HOME:-~/.codex}/sessions`: Codex rollout root.
- `WARP_RESUME_CODEX_INDEX=${CODEX_HOME:-~/.codex}/session_index.jsonl`: Codex's append-only name index.

Use absolute paths for path overrides. Launch flags are a standing choice, not captured from individual sessions. Native harness retention and resume behavior still apply.

## Details and safeguards

The prompt reads the recorded transcript when it is a readable regular file under the configured harness root. Otherwise, it looks up that exact session ID in the native transcript layout. Roots and candidates are canonicalized, including symlinks, before reading.

Claude keeps the original title selection: custom `/rename` title, generated title or summary, then the first typed prompt. Codex uses the latest matching thread-name index entry, then the first typed prompt. Legacy `user_message` events and completed `UserMessage` items are merged in transcript order, retaining older history and genuinely repeated prompts. Repeated completed item IDs are counted once; opposite-format views with a shared client ID are paired one-to-one. Without correlation, occurrences are preserved rather than guessed to be duplicates. Raw user-role context and tool traffic are ignored.

Details include transcript modification age, size, prompt count, and the last typed message. Transcript text is sanitized and truncated before literal display. Missing or unreadable transcripts omit the details; missing or broken Python omits text and counts, but keeps age and size. Details are best-effort and do not affect which session is resumed.

Records contain exactly one complete line with five tab-separated fields: harness, session ID, directory, timestamp, and optional transcript path. They contain no conversation text or executable options. Directories are `0700`, and files are `0600`; updates use a temporary file and atomic rename.

Unknown harnesses, invalid IDs, malformed records, and control characters in record paths are silently rejected. Only allowlisted adapter code chooses executable names and argument order. Executables are resolved to absolute paths before `builtin cd`; record data is never evaluated or prompt-expanded. `warp-resume-list` escapes control characters.

Without working Python, the recorder uses a conservative POSIX-awk fallback for small, flat JSON objects with literal session IDs and directory strings, including literal UTF-8 paths. It validates complete structure, field types, and UTF-8, but does not unescape required fields or accept nested values and ambiguous keys. Unsupported inputs leave existing bindings unchanged. Working Python supports the full hook JSON shape and escaped paths.

## Caveats

- The pane UUID variable is currently undocumented. If Warp changes or removes it, binding stops working without launching an unrelated session.
- Only panes restored with their original UUID can match a record. New layouts, SSH panes, and other environments are not recovered by this integration.
- Accepting a resume changes to the recorded directory and runs normal `chpwd` hooks, such as direnv. Auto mode does this without asking.
- If confirmation is enabled but there is no terminal, the integration prints a notice and does not launch.
- Shell path validation is locale-dependent. Under `LANG=C`, only ASCII controls are rejected; Unicode formatting characters in paths can still affect their visual presentation on some systems. Transcript text has separate Unicode sanitization.
- Records are never automatically pruned. Forget individual bindings explicitly.

## Development and verification

```sh
bash test.sh
sh -n record-session.sh
zsh -n warp-resume.zsh
```

The suite preserves the original 84 regression cases and adds both harnesses, switching, exact argv, invalid inputs, transcript variants, custom and symlinked roots, absent Python, and PTY consent and startup behavior. It creates no real harness sessions. If ShellCheck is available, also run:

```sh
shellcheck -s sh --enable=all record-session.sh
```

A real Warp restart is a separate manual smoke test after installation:

1. Start two Claude sessions and two `codex --no-daemon` sessions in separate panes sharing one directory.
1. Submit distinct identifying prompts, ensuring Codex's hooks are trusted and its first-turn hooks have run.
1. Check `warp-resume-list` for the correct harness and different session IDs.
1. Restart Warp manually, accept each offer, and confirm each pane returns to its own conversation.
1. Check that declining, auto mode, a new pane, and `warp-resume-forget` behave as expected.

This port has not yet undergone that real-restart smoke test. Creating the port does not install it, edit user configuration, or restart Warp.

## Uninstall

Set `WARP_RESUME_DISABLE=1` before sourcing to stop automatic offers immediately. To remove the integration:

1. Remove its source line and `WARP_RESUME_*` settings from `.zshrc`.
1. Remove only its `SessionStart` handlers from the selected harness configuration.
1. Remove the installed `~/.warp-resume` scripts and records when no longer needed, reviewing any custom state location first.

Claude and Codex conversations remain in their own configuration directories and are unaffected.

## License

MIT. The original copyright and attribution are preserved in [LICENSE](LICENSE).
