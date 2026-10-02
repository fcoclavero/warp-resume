# warp-resume

Per-pane Claude Code and Codex CLI resume for Warp. A faithful, harness-agnostic port of `warp-claude-resume`; two runtime shell scripts and no build step.

## Layout

- `record-session.sh`: POSIX-sh `SessionStart` hook. Requires `claude-code` or `codex-cli` as its first argument and writes a private, atomic five-field pane record.
- `warp-resume.zsh`: sourced from `.zshrc`; registers a one-shot `precmd` hook and provides manual resume, list, and forget commands.
- `test.sh`: Bash regression suite with isolated HOME/ZDOTDIR, stub CLIs, transcript fixtures, and PTY tests.
- `README.md`: manual installation, controls, limitations, and smoke-test instructions.
- `CLAUDE.md`: imports these shared instructions.
- `LICENSE`: original MIT attribution.

## Working on this

Run `bash test.sh` before and after code changes. All checks must pass; unreadable-file checks may skip under root, and PTY checks skip if the module is unavailable. Test fixtures require working Python 3, but runtime Python remains optional.

Also run `sh -n record-session.sh`, `zsh -n warp-resume.zsh`, and `bash -n test.sh`. Run `shellcheck -s sh --enable=all record-session.sh` if available; do not install dependencies silently. Format every Markdown edit with `mdformat`.

Read existing comments before simplifying code. Several original safeguards look redundant but protect against reproduced shell-option, alias, PATH, terminal-injection, or prompt-framework failures.

## Constraints

- Keep the recorder POSIX sh: no `[[`, arrays, `local`, or `pipefail`.
- Keep dispatch allowlisted and small. Records must never supply executables, flags, or arbitrary adapters.
- Preserve five fields: harness, session ID, absolute cwd, numeric timestamp, and optional absolute transcript path. Preserve empty optional fields when reading. Unknown schemas fail closed.
- Keep flags in separate zsh arrays. Codex resumes must include `--no-daemon`; initial tracked launches also require it. Do not add CLI wrappers or intercept normal launch commands.
- Preserve deferred, one-shot startup, double-source and nested-shell guards, and SSH exclusion. Definitions must source safely under nondefault zsh options.
- Resolve an absolute executable before changing directory; use `builtin cd` and literal data display. Never send untrusted data through `print -P` or evaluate record content.
- The recorder's sole `eval` is fixed Python-generated assignments using `shlex.quote`. Reject NUL and invalid UTF-8 before shell conversion. The unevaluated no-Python fallback validates a conservative flat-object subset; unsupported or ambiguous input must preserve existing bindings.
- Details are best-effort. Confine physically canonical transcript paths to configured roots and read the validated path. Use `:P`, not `:A`, which normalizes parent components before following symlinks. Reject special files and sanitize Unicode text before display.
- Preserve legacy-only Codex history when modern user items appear later. Deduplicate repeated completed item IDs and pair shared-client-ID opposite views one-to-one. Do not deduplicate by text or turn; identical prompts can be real repeats.
- Read exactly one complete TSV line, including the empty optional fifth field; reject extra lines or trailing bytes. PTY tests must prove a command handshake and normal child exit, not just find a prompt-looking token.
- Keep records private and atomic. Never automatically prune, migrate old state, edit installed configuration, restart Warp, or run real harness sessions as part of tests.
- Preserve the original MIT copyright. Do not change the sibling original repository.

## Validation status

The original 84 cases pass on the port, and the expanded suite covers both harnesses on macOS/zsh 5.9.2. Linux, WSL, and a real Warp restart remain unverified; do not claim otherwise.
