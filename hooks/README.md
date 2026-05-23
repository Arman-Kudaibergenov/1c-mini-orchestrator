# Hooks

Optional [Claude Code hooks](https://docs.claude.com/en/docs/claude-code/hooks) for the orchestrator. They are **opt-in**: shipped as scripts here, **not** auto-wired. To enable them, point your Claude Code `settings.json` at the absolute path of the script you want and set the matching opt-in environment variable.

All scripts are sanitized: no hardcoded hostnames, no calls to the author's private infrastructure. They read the standard hook event JSON from stdin, write log lines to `$TEMP\orch-*.log`, and (for the RLM family) speak MCP JSON-RPC to whatever URL `ORCH_RLM_URL` points at.

Windows-only (`powershell.exe`, paths assume `C:\`, log dirs use `$env:TEMP` / `$env:USERPROFILE`). Pwsh 7 is untested.

## Inventory

22 files: 19 hook scripts (one per script per event) + 4 shared libs under `lib/`. Sorted into 4 tiers by external dependencies.

### Tier 1 — works out of the box

No external services, no extra scripts. Pure stdin/stdout + local filesystem. Safe to enable on a fresh laptop.

| Script | Event | Opt-in env | Purpose |
|---|---|---|---|
| `bash-guard.ps1` | PreToolUse | — | Warns before noisy test runners (`pytest`, `npm test`, …) without output redirect. Prevents stdout flooding the agent's context. |
| `auto-capture.ps1` | PostToolUse | — | Appends Edit/Write/notable-Bash events to `~/.claude/orch-autocapture-buffer.jsonl`. Buffer is drained on demand by the "суммаризируем" ritual. |
| `mcp-stats.ps1` | PostToolUse | — | Logs every tool call to `~/.claude/orch-mcp-stats.jsonl` (10 MB rolling). For post-hoc analysis. |
| `handoff-write-guard.ps1` | PreToolUse | — | Blocks Write/Edit/MultiEdit on `*-ready.flag` when the proposed content fails the handoff schema. Uses `lib/handoff-validator.ps1` only — no network. |
| `stop-autonomous-chain.ps1` | Stop | `ORCH_AUTONOMOUS_CHAIN=1` | Re-prompts the agent up to 4×/5min to keep an autonomous chain moving instead of stalling at end-of-turn. Kill-switch: `~/.claude/.orch-autonomous-off`. Uses `lib/handoff-state.ps1`. |
| `post-phase-validate.ps1` | SessionEnd | `ORCH_AUTO_VALIDATE=1` | Orchestrator-specific. When an L3 phase session ends, auto-runs the matching `scripts/validate-*.ps1` against the task. Requires `ORCH_PHASE` + `ORCH_TASK_ID` to be set by the spawner — the shipped `spawn-*.ps1` do **not** set these. |

### Tier 2 — requires RLM

Requires an RLM (Reactive Long Memory) MCP server reachable over HTTP. Set `ORCH_RLM_URL=http://<host>:<port>/mcp`. Without it the scripts exit silently or log a warning. Setup for RLM itself: see [Arman-Kudaibergenov/rlm-workflow](https://github.com/Arman-Kudaibergenov/rlm-workflow).

| Script | Event | Purpose |
|---|---|---|
| `pre-compact.ps1` | PreCompact | Before Claude Code compacts the conversation, saves session state to RLM. PreCompact stdout is **not** injected back, so the save must be direct HTTP. |
| `post-compact-restore.ps1` | SessionStart (compact) | After a compact, queries RLM for PENDING tasks + pre-compact facts and injects them via stdout so the post-compact context is rehydrated. |
| `session-end-save.ps1` | SessionEnd | Records session summary (files modified, git state, tool counts) to RLM. Optionally pokes a tunnel-keepalive script — see `ORCH_RLM_TUNNEL_SCRIPT` below. |
| `session-start-restore.ps1` | SessionStart (startup/resume/clear) | Three paths: (1) **RELAY** — picks up `$TEMP\orch-dispatch\relay-pending.json` if a parent session handed off; (2) **RESUME/CLEAR** — queries RLM for last session of this project; (3) **STARTUP** — exits silently. |
| `periodic-flush.ps1` | PostToolUse (Edit\|Write) | Every 20 mutations, flushes modified-file list to RLM. Fast path (<10 ms) the other 19 calls. |
| `subagent-stop-verify.ps1` | SubagentStop | Saves subagent result summary to RLM for cross-session visibility. |
| `rlm-health-gate.ps1` | SessionStart | Diagnostic only — pings `ORCH_RLM_URL`, warns the user if unreachable. Cannot fix MCP wiring (too late), only inform. |

Optional env: `ORCH_RLM_TUNNEL_SCRIPT` — path to a bash script that ensures the RLM tunnel is alive before HTTP writes. Skipped if unset.

### Tier 3 — requires statusline writing ctx-state

The context state-machine (`context-guard` + `context-monitor`) reads per-session JSON written by your **statusline script**. The orchestrator does not ship a statusline — you write one yourself (or adapt the snippet below).

Expected file: `$env:TEMP\claude-ctx-state-sess-<session_id>.json`, refreshed on every statusline render.

```json
{
  "sessionId": "<session_id>",
  "tokens": 412345,
  "effectiveLimit": 800000,
  "pct": 51
}
```

`pct` is "% of effectiveLimit consumed". Bands used by `context-monitor.ps1`:

| effectiveLimit | ARMED at | COMPLIANCE at |
|---|---|---|
| 1M-class (≥ 700k) | ≤ 85 % remaining | ≤ 75 % remaining |
| 200k-class | ≤ 62 % remaining | ≤ 21 % remaining |

| Script | Event | Purpose |
|---|---|---|
| `context-guard.ps1` | PreToolUse | When state = COMPLIANCE, narrows the tool whitelist to handoff-only (RLM/Bash/Read). Falls back to legacy %-thresholds if the state file is missing. |
| `context-monitor.ps1` | PostToolUse | Drives the state machine `IDLE → ARMED → COMPLIANCE → HANDOFF_VALIDATED → ROTATED`. On COMPLIANCE entry saves a baseline RLM fact and writes `rlm-saved.flag`. (RLM HTTP — Tier 2 also applies if you want the baseline-save side-effect.) |

If you skip Tier 3, both scripts exit silently — they're safe to wire even without a statusline, just useless.

### Tier 4 — requires external scripts

These read environment variables that point at scripts/files the orchestrator does not ship. Useful only if you have your own integrations to bolt on. All exit silently when the env var is empty.

| Script | Event | External dep (env) | Purpose |
|---|---|---|---|
| `stop-rotate.ps1` | Stop | `ORCH_ROTATE_SCRIPT` → path to your rotation script | After state = HANDOFF_VALIDATED, runs cooldown/grace checks then invokes your rotator (typically spawns a fresh `wt` tab with the relay payload). Also reads `ORCH_AUTO_ROTATE=1`, `ORCH_ROTATE_COOLDOWN_SEC`, `ORCH_ROTATE_GRACE_SEC`, `ORCH_RELAY_ACK_SCRIPT`. |
| `dispatch-inbox.ps1` | PostToolUse | `ORCH_DISPATCH_DB` → path to sqlite DB | Polls (max 1×/30s) a sqlite inbox for completed dispatch messages and surfaces them. Skips if the DB file is absent. |
| `dispatch-tool-log.ps1` | PostToolUse | `ORCH_DISPATCH_LOG` → path to JSONL file | Appends a JSONL row per tool call into the named file. Zero cost when the env var is unset. |
| `session-end-hygiene.ps1` | SessionEnd | `ORCH_HYGIENE_SCRIPT` → path to a script | Runs the script at most once per 24 h (cooldown tracked in `$TEMP\orch-hygiene-last.txt`). Async — does not block session exit. |

## Wiring

Two scopes; pick one. Hook commands must be the **absolute path** to the `.ps1` — Claude Code does not interpolate from `$cwd`.

### Scope A — global (one user, all projects)

Edit `~/.claude/settings.json` (create if missing). Below is the maximal wiring for a Tier-1 + Tier-2 setup. Drop blocks you don't want.

```json
{
  "env": {
    "ORCH_AUTONOMOUS_CHAIN": "1",
    "ORCH_AUTO_VALIDATE": "1",
    "ORCH_RLM_URL": "http://<rlm-host>:8250/mcp"
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"C:\\path\\to\\1c-mini-orchestrator\\hooks\\bash-guard.ps1\"" },
          { "type": "command", "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"C:\\path\\to\\1c-mini-orchestrator\\hooks\\context-guard.ps1\"" },
          { "type": "command", "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"C:\\path\\to\\1c-mini-orchestrator\\hooks\\handoff-write-guard.ps1\"" }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"C:\\path\\to\\1c-mini-orchestrator\\hooks\\auto-capture.ps1\"" },
          { "type": "command", "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"C:\\path\\to\\1c-mini-orchestrator\\hooks\\mcp-stats.ps1\"" },
          { "type": "command", "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"C:\\path\\to\\1c-mini-orchestrator\\hooks\\context-monitor.ps1\"" }
        ]
      },
      {
        "matcher": "Edit|Write",
        "hooks": [
          { "type": "command", "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"C:\\path\\to\\1c-mini-orchestrator\\hooks\\periodic-flush.ps1\"" }
        ]
      }
    ],
    "PreCompact": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"C:\\path\\to\\1c-mini-orchestrator\\hooks\\pre-compact.ps1\"" }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "compact",
        "hooks": [
          { "type": "command", "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"C:\\path\\to\\1c-mini-orchestrator\\hooks\\post-compact-restore.ps1\"" }
        ]
      },
      {
        "matcher": "startup|resume|clear",
        "hooks": [
          { "type": "command", "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"C:\\path\\to\\1c-mini-orchestrator\\hooks\\session-start-restore.ps1\"" },
          { "type": "command", "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"C:\\path\\to\\1c-mini-orchestrator\\hooks\\rlm-health-gate.ps1\"" }
        ]
      }
    ],
    "SessionEnd": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"C:\\path\\to\\1c-mini-orchestrator\\hooks\\session-end-save.ps1\"" },
          { "type": "command", "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"C:\\path\\to\\1c-mini-orchestrator\\hooks\\post-phase-validate.ps1\"" }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"C:\\path\\to\\1c-mini-orchestrator\\hooks\\stop-autonomous-chain.ps1\"" },
          { "type": "command", "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"C:\\path\\to\\1c-mini-orchestrator\\hooks\\stop-rotate.ps1\"" }
        ]
      }
    ],
    "SubagentStop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"C:\\path\\to\\1c-mini-orchestrator\\hooks\\subagent-stop-verify.ps1\"" }
        ]
      }
    ]
  }
}
```

### Scope B — per-project (only when this repo is cwd)

Same JSON, placed at `<repo>/.claude/settings.json`. The repo's `.gitignore` excludes `.claude/`, so the file stays local — commit it explicitly if you want it tracked.

## Environment variables — full list

| Variable | Tier | Default | Meaning |
|---|---|---|---|
| `ORCH_AUTONOMOUS_CHAIN` | 1 | unset (off) | `=1` → enable `stop-autonomous-chain` re-prompting |
| `ORCH_AUTO_VALIDATE` | 1 | unset (off) | `=1` → enable `post-phase-validate` |
| `ORCH_PHASE` | 1 | unset | Set by L3 spawner; one of `analyst\|sdd-writer\|implementer\|auditor` |
| `ORCH_TASK_ID` | 1 | unset | Set by L3 spawner; task id for `post-phase-validate` |
| `ORCH_PROJECT` | 1 | unset | Optional project tag for log breadcrumbs |
| `ORCH_RLM_URL` | 2 | unset → RLM hooks no-op | Base MCP URL, e.g. `http://<host>:8250/mcp` |
| `ORCH_RLM_TUNNEL_SCRIPT` | 2 | unset → tunnel check skipped | Path to bash script that keeps RLM tunnel alive |
| `ORCH_AUTO_ROTATE` | 4 | unset (off) | `=1` → `stop-rotate` will actually spawn (otherwise it just logs) |
| `ORCH_ROTATE_SCRIPT` | 4 | unset → no spawn | Path to your rotation script |
| `ORCH_ROTATE_COOLDOWN_SEC` | 4 | (script default) | Min seconds between rotations per session |
| `ORCH_ROTATE_GRACE_SEC` | 4 | (script default) | Grace window after HANDOFF_VALIDATED before spawning |
| `ORCH_RELAY_ACK_SCRIPT` | 4 | unset → no ack | Path to script invoked after child terminal acknowledges relay |
| `ORCH_DISPATCH_DB` | 4 | unset → hook no-op | Path to sqlite inbox DB |
| `ORCH_DISPATCH_LOG` | 4 | unset → hook no-op | Path to JSONL tool-log file |
| `ORCH_HYGIENE_SCRIPT` | 4 | unset → hook no-op | Path to hygiene cleanup script |

## Verification

After editing `settings.json`, **restart Claude Code**. To confirm a hook is firing:

```powershell
Get-Content $env:TEMP\orch-stop-autonomous-chain.log -Tail 20
Get-Content $env:TEMP\orch-post-phase-validate.log -Tail 20
Get-Content $env:TEMP\orch-relay.log -Tail 20
# … and so on; each hook writes its own orch-*.log under $TEMP.
```

If a log never appears after the matching event, the hook isn't wired — re-check the absolute path in `settings.json` and that the opt-in env var is set.

## Caveats

- **Token cost** of `stop-autonomous-chain`: when enabled, it can spend up to 4 re-prompts even if the chain is genuinely done but the agent forgot to emit `## CHAIN COMPLETE` / a HANDOFF / `## BLOCKED:`. Enable only for unattended runs.
- **`post-phase-validate`** does nothing unless `ORCH_PHASE` + `ORCH_TASK_ID` are injected into the L3 session. The shipped `spawn-*.ps1` do not do this yet — patch them yourself (one `--env ORCH_PHASE=… --env ORCH_TASK_ID=…` per spawner).
- **`context-guard` + `context-monitor`** without a statusline-emitted ctx-state file fall back to legacy %-thresholds (PID-scoped) which can false-fire across concurrent sessions. Either provide a statusline or skip both.
- **RLM hooks** swallow network errors silently (by design — hooks must not break sessions). Tail the per-hook log to see real reasons for skipped saves.
- **Tier 4 hooks** all exit silently when their env var is empty — wiring them globally is safe, they just no-op.
