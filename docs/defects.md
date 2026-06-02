---
ledger: defects
counters:
  milestone: 0
  item: 0
archives: []
---

# defects

---

## D01 — Agent violated Nix store access rule (recursive find on /nix/store)

**Status**: [~] remediation applied (prompt rule strengthened; behavioural verification pending over future sessions)  
**Severity**: medium  
**Date reported**: 2026-06-02  
**Source**: self-report during pi internals investigation (xai integration + system prompt questions)

**Headline**: Agent emitted a recursive `find /nix/store -path '*pi*monorepo*'` tool call, violating the mandatory Nix store access discipline in project guidelines.

**Description**:
The agent used a broad recursive traversal of the Nix store (expensive full stat even when truncated by `head`) instead of the required procedure (PATH resolution first via `realpath "$(command -v ...)"`, then depth-1 `ls -d` or `find -maxdepth 1`).

Full reproduction, root cause analysis, impact, and detailed remediation proposal (including exact strengthened rule text) are in the draft report.

**Root cause**:
Guideline present in prompt (from `pkg/llm-prompts/context.md` → `~/.pi/agent/AGENTS.md`) but too weak to override strong shell-exploration habit. Current text is a buried negative sentence without a forced pre-tool-call decision procedure, explicit "forbidden" examples, or early trigger.

**Suggested fix**:
Replace the "Nix store queries" bullet in the master source (`pkg/llm-prompts/context.md`) with the mandatory procedural version (detailed in the draft). Elevate visibility. Re-activate Home Manager to propagate the new `AGENTS.md`.

**Draft report** (rich detail, verification criteria, references):
`docs/drafts/20260602-2312-nix-store-rule-violation.md`

**Tags**: [instructions-defect], [nix], [agent-reliability], [pi]

**Remediation applied** (2026-06-02):
Rewrote the "Nix store queries" bullet in `pkg/llm-prompts/context.md` §9 as
**"Nix store discipline — resolve, don't scan"**: positive-first ordered procedure
(build-graph resolution as the *required* step 1, not a "better still" afterthought),
the exact forbidden `-path '*foo*'` form named explicitly, and an urge-trigger sentence.
`./verify-configs --verbose vm` passes (AGENTS.md regenerates from the new source).

**Open follow-ups**:
- Behavioural verification: over future sessions, confirm "locate installed artifact"
  tasks use `command -v`/`nix eval`/depth-1 first and emit no recursive `/nix/store` find.
- **Stronger, deterministic option** (not yet done): a PreToolUse bash guard (Claude
  Code hook) + a Pi tool-call-interception extension that rejects `find /nix/store`
  without `-maxdepth 1` outright — fail-fast at the boundary rather than relying on the
  probabilistic prompt rule. The global `~/.claude/CLAUDE.md` carries the same old
  wording and is outside this repo (needs the exchange-script workflow to sync).
- After behavioural verification, move summary to archive per review-loop discipline and close D01.

