# Defect Report: Agent violated Nix store access rule

**ID**: D01 (see `./docs/defects.md`)  
**Date**: 2026-06-02  
**Severity**: medium  
**Status**: open  
**Reporter**: agent self-report (during exploration of pi internals)  
**Source**: conversation about pi system prompt + xAI plugin; exact tool call below.

## Observed Behavior

The agent emitted the following `bash` tool call:

```bash
find /nix/store -path '*pi*monorepo*' -type d 2>/dev/null | head -5
```

This is a recursive traversal of the entire Nix store root (millions of top-level entries + deep package trees) even though the output is later truncated by `head`.

## Expected Behavior (per project guidelines)

From the loaded project instructions (`AGENTS.md`, populated from `pkg/llm-prompts/context.md`):

> **Nix store queries**: Never `find /nix/store …` recursively — the store holds millions of paths and a full traversal costs minutes of stat churn. The store is flat: every package is a top-level `/nix/store/<hash>-<name>` directory, so match at depth 1 — `ls -d /nix/store/*<name>*` or `find /nix/store -maxdepth 1 -name '*<name>*'` — then descend into the single hit. Better still, resolve paths through the build graph instead of the filesystem: `realpath "$(command -v <bin>)"` for an on-PATH binary, or `nix path-info <flakeref>#<attr>` / `nix eval --raw <flakeref>#<attr>` for a package's out-path.

The rule explicitly prefers build-graph resolution and depth-1 operations. The violation occurred while the rule was active in the prompt (under `<project_instructions>`).

## Steps to Reproduce

1. Running in the `nix-config` working tree (which loads `AGENTS.md` / context from `pkg/llm-prompts/context.md` via Home Manager + `mk-agent-harness.nix`).
2. Task: investigate the installed `pi` coding agent (0.78.0) to answer questions about its system prompt construction and xAI (`pi-xai-oauth`) integration plugin.
3. Agent chose to discover the package contents via a broad `find` on `/nix/store` instead of the mandated first steps.

## Root Cause Analysis

The guideline was present but insufficient to override a strong prior habit ("quick filesystem discovery").

Specific weaknesses in the current formulation (located in `pkg/llm-prompts/context.md`, Section 9 "Tools"):

1. **Low salience**: Buried deep in a long bullet list under "9. Tools".
2. **Purely negative framing**: "Never ..." without a forced positive decision procedure that must be executed *before* any tool call involving the store root.
3. **"Better still" weakens priority**: The recommended methods (PATH resolution first) are presented as an improvement rather than the required first action.
4. **No execution-time gate**: No explicit instruction of the form "When you are about to emit a `bash` call referencing `/nix/store`, you **MUST** first apply the following checklist...".
5. **Missing concrete counter-examples**: No "do not emit" list that matches the exact bad pattern used (`find /nix/store -path '*...*'`).
6. **Habit competition**: General shell/Unix exploration patterns are extremely well-trained; a single "never" sentence is weak against them.
7. **No early warning**: No short trigger sentence near the top of the document or in "References" that fires when the agent feels the urge to locate installed artifacts.

The rule correctly identifies the problem (full stat churn) and the solutions, but fails at the critical interface between reasoning and tool emission.

## Impact

- Defeats the performance invariant the rule was written to protect.
- In larger closures or on slower storage, the cost is real (the `head` truncation is a false sense of safety — `find` still walks before producing output).
- Risk of similar violations whenever an agent needs to locate Nix-installed artifacts (very common in this repository: pi, ollama-sycl, custom packages, etc.).
- Meta-defect: the instructions that govern the agent itself contain a defect in how they constrain the agent's tool use.

## Proposed Remediation

**Primary change location**: `/home/pavel/work/safe/nix-config/pkg/llm-prompts/context.md` (the canonical source that becomes `~/.pi/agent/AGENTS.md` and the `<project_instructions>` blocks for pi and other harnesses managed by `lib/mk-agent-harness.nix`).

### Strengthen the rule to a mandatory procedure

Replace the current bullet with a version that:

- States the invariant and cost up front.
- Defines an **exact, ordered decision procedure** that must be followed before any top-level store access in a tool call.
- Makes PATH/build-graph resolution the **required first step** for the common case (installed binaries).
- Explicitly lists forbidden patterns with examples that match what was actually emitted.
- Adds a "when you feel the urge..." red-team trigger.
- Prefers `nix` commands and known symlinks over raw discovery.
- Elevates the rule's visibility (consider a short summary + pointer higher in the document, e.g. under "2. References" or a new top-level "Nix discipline" item).

See the full proposed text in the "Proposed strengthened rule" section below.

### Secondary improvements

- Move a one-sentence early warning higher in the guidelines (or duplicate the trigger sentence).
- Add the rule (or a link) to the pi-specific or general "how to explore the environment" guidance.
- Consider adding a tiny runtime reminder in the system prompt construction for Nix-heavy projects (future).

## Proposed Strengthened Rule (exact text for `context.md`)

```markdown
- **Nix store access discipline (mandatory procedure)**: The Nix store is a flat directory containing millions of entries. Any recursive traversal (`find /nix/store`, `ls -R /nix/store`, `find /nix/store -path ...` without `-maxdepth 1`, etc.) is forbidden because it performs an expensive full scan even when later piped to `head`.

  **Before you may emit any shell command that touches `/nix/store` at the top level, you MUST follow this exact sequence:**

  1. **If the target is an installed command, binary, or package you expect to be on PATH** (the common case when looking for `pi`, `ollama`, a library, etc.):
     - First attempt: `realpath "$(command -v <bin>)"` or `command -v <bin>`.
     - This resolves through the build graph / profile without any store traversal.

  2. **If you need to discover the store path by name** (and step 1 did not suffice):
     - Use only depth-1 operations on the store root:
       ```bash
       ls -d /nix/store/*<exact-or-glob-name>*
       # or
       find /nix/store -maxdepth 1 -name '*<name>*'
       ```
     - Never use `-path` that can match deep inside packages unless you already have a concrete top-level store path in hand.

  3. **Only after obtaining a concrete top-level store path** (e.g. `/nix/store/abc123-foo-1.2`) may you descend into it with ordinary `ls`, `cat`, `find ... -maxdepth N` etc. on that specific subtree.

  **Explicitly forbidden (examples of what you must not emit)**:
  - `find /nix/store -path '*something*' ...`
  - `find /nix/store ...` (any recursive find without `-maxdepth 1`)
  - `ls -R /nix/store` or similar deep listings
  - Any command whose first argument after the tool is a bare `/nix/store` glob that would cause recursive behavior

  **Rationale and enforcement**: The store is intentionally not indexed for recursive search by agents. When you feel the urge to "just quickly find where X is installed", that is the exact moment you must stop and apply the procedure above. Prefer `nix path-info`, `nix eval --raw`, or reading from known symlinks in `~/.nix-profile`, `/run/current-system`, or Home Manager generations instead of raw filesystem discovery.

  If the information is only available by inspecting a derivation or closure, use `nix path-info -r` or similar rather than walking the store.

  This rule takes precedence over any "quick exploration" habit.
```

## Verification Criteria (for the fix)

- After the change, re-activate the relevant Home Manager / pi configuration so the new `AGENTS.md` / context is in effect.
- Repeat similar exploration tasks (e.g., "find where the pi package files live") and confirm the agent uses `realpath "$(command -v pi)"` or `ls -d /nix/store/*pi-coding-agent*` first.
- No future tool calls should contain recursive `find /nix/store` (without `-maxdepth 1`) or `-path` from the root in this or other Nix-heavy projects using the prompt bundle.
- The strengthened language should be sufficient that a future review of the transcript shows the procedure being followed (or the agent explicitly asking the user for clarification instead of violating).

## References

- Master source: `/home/pavel/work/safe/nix-config/pkg/llm-prompts/context.md` (Section 9, "Nix store queries" bullet)
- Generated runtime file: `~/.pi/agent/AGENTS.md` (symlink into a Nix store path produced by `programs.pi` + `mk-agent-harness.nix`)
- Exact violating call: `find /nix/store -path '*pi*monorepo*' -type d 2>/dev/null | head -5`
- Good methods demonstrated later in same session: `realpath "$(command -v pi)"` and `ls -d /nix/store/*pi-coding-agent*`
- Project structure docs: `CLAUDE.md`, `lib/mk-agent-harness.nix`, `modules/hm/programs-pi.nix`
- Related skills/ledgers: `pkg/llm-prompts/skills/review-loop/`, `docs/defects.md`, `docs/ledgers.yaml`

## Notes

This is a defect in the *instructions that govern the agent*, not in the agent's core code or in pi itself. Fixing it improves reliability for all agents (pi, and others using the same llm-prompts bundle) on NixOS/Nix-darwin systems.

After remediation, this report should be moved (or summarized) into `./docs/archive/defects-*.md` per the review-loop discipline, with a pointer left in the active `./docs/defects.md`.
