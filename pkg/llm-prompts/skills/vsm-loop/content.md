# VSM Loop: Viable-System Orchestration for Multi-Agent R&D

A meta-workflow for running hierarchies of subagents under Stafford
Beer's Viable System Model (VSM). Use this when the work is large
enough to span multiple research and build cycles, recursive
sub-tasks, or long-running R&D where explicit discipline about *who
decides what*, *what crosses each channel in what form*, and *when
to escalate to the user* will pay back the overhead.

This skill is the **strategic and managerial** layer. Inside it,
compose [[review-loop]] for build–fix–review cycles and
[[research-loop]] for investigation cycles. Sub-tasks substantial
enough to be viable systems of their own follow the [[vsm-node]]
recursion contract, so the hierarchy stays viable at every level.

## VSM in one paragraph

A *viable system* is one that can sustain a separate existence in
its environment. Beer identifies five subsystems present in any such
system:

- **S1 — Operations.** The units actually doing the primary work.
- **S2 — Coordination.** Protocols and conventions that prevent
  S1s from conflicting (Beer's "anti-oscillation").
- **S3 — Operational management** ("Inside-and-Now"). Allocates
  resources across S1s, runs today's operations.
- **S3\* — Audit channel.** Sporadic, direct inspection of S1s
  that bypasses their self-report.
- **S4 — Strategy/Intelligence** ("Outside-and-Future"). Models the
  environment, plans, researches.
- **S5 — Policy/Identity** ("Ethos"). Sets purpose, balances S3
  against S4, holds the system's identity.

Two cross-cutting mechanisms make the model work:

- **Variety engineering** (Ashby's Law of Requisite Variety): each
  channel between systems *attenuates* variety on the way up
  (compress, summarize) and *amplifies* variety on the way down
  (expand, specify), so each level operates within its cognitive
  bandwidth.
- **Algedonic channel**: a "pain/pleasure" signal from S1 straight
  to S5, bypassing the normal hierarchy, used only when something
  is intolerable or requires identity-level judgement.

## Mapping VSM onto an agent hierarchy

| VSM | Function | Realization in this loop |
|-----|----------|--------------------------|
| **S5** | Sets goals, holds non-negotiables | User + main session in identity/policy capacity. `CLAUDE.md`, project constraints, "what must always be true." |
| **S4** | Plans, researches, models | Planning subagents; [[research-loop]] invocations; design-deliberation subagents. |
| **S3** | Allocates work here-and-now | Main session as orchestrator: dispatches subagents, maintains ledgers, decides parallelism, sequences cycles. |
| **S3\*** | Direct audit of S1 | Adversarial review subagents ([[review-loop]] I2); verification subagents that re-read raw code or re-run tests instead of trusting executor self-report. |
| **S2** | Conflict damping, conventions | Ledger format and locking, defect ID schema, worktree isolation, naming conventions, parallel-vs-serial discipline. |
| **S1** | The actual work | Execution subagents (code, tests, edits). For substantial S1 tasks, the subagent runs its own vsm-loop per [[vsm-node]]. |

The S1 units in this mapping are themselves viable systems
internally: an execution subagent that gets a non-trivial task
spawns its own planner, executor, and reviewer, with its own S5
(its brief), its own S2 (its ledger subsection), and its own
escalation channel back up to its parent. Recursion is bounded —
at the leaves, the work is atomic and the subagent simply does it.

## Non-negotiable rules

- **You (the main session) operate at S3.** You never gather
  evidence yourself, you never plan in detail yourself, you never
  write production code yourself. Your work is dispatch, ledger
  maintenance, transduction across channels, audit interpretation,
  and escalation. Every other phase runs in a subagent.
- **Variety must change at every channel crossing.** Down the
  hierarchy → expand (a one-line goal becomes a brief with file
  paths, examples, acceptance criteria, recursion contract). Up
  the hierarchy → compress (a 30-file diff becomes a structured
  summary; a session's worth of cycles becomes a one-screen
  status). A subagent return that contains raw code, unfiltered
  findings, or step-by-step narration has failed transduction —
  re-brief with a compression contract, or attenuate it yourself
  before passing further up.
- **The ledger is the institutional memory.** It survives across
  sessions, subagent lifecycles, and recursion levels. Active
  work lives in `./tasks.md` (current goal, plan, in-progress
  entries, recent defects). Completed work migrates to
  `./archive/tasks-YYYY-MM.md` with a one-line stub left in
  `./tasks.md`. Never delete; only flip state, append, or migrate.
- **Subagents are locally autonomous within their brief.** You
  set the goal, the success criteria, the file scope, and the
  recursion permission. Inside that envelope, the subagent
  decides how to do the work and what intermediate steps to
  take. Do not micromanage; do audit.
- **Algedonic is rare and structured.** A subagent escalates to
  the user only when the brief cannot be discharged from inside
  the loop *and* the resolution requires authority above S3:
  missing credential, contradictory requirement, architectural
  choice needing user input, safety/security finding requiring
  policy judgement. Everything else stays in the loop —
  including "I'm stuck" (route to S4 / more research) and "this
  is harder than estimated" (route to S4 / replan).
- **One ledger entry = one S1 cycle = one commit.** S2
  discipline. Cycles that bleed into each other corrupt the
  audit trail.

## Variety engineering: the transduction discipline

The single most common failure mode of multi-agent orchestration
is *variety mismatch*: too much detail at a level that needed a
summary, too little detail at a level that needed a brief.
Operationally:

**Going down (S5 → S4 → S3 → S1) — amplification.** Each channel
adds specificity the downstream level needs to act:

- **S5 → S4** (user / main session → planner): goal +
  non-negotiables + in/out of scope + budget constraint. The
  planner expands this into a milestone breakdown, PR sequence,
  risk register, and acceptance criteria per unit.
- **S4 → S3** (plan → orchestrator): plan + acceptance criteria
  + cross-cutting decisions. The orchestrator turns each plan
  entry into a ledger row with an entry-specific brief and
  decides dispatch order and parallelism.
- **S3 → S1** (orchestrator → executor): self-contained brief —
  exact file paths, success criteria as runnable commands, the
  relevant excerpt from the plan, in/out scope for this unit,
  what the parent will inspect on return, and the [[vsm-node]]
  recursion contract if recursion is permitted.

The downstream subagent must never have to ask *"what did they
mean?"* — the upstream level already paid the cost of expansion.
If a subagent has to re-derive context from the codebase, your
brief failed.

**Going up (S1 → S3 → S4 → S5) — attenuation.** Each channel
strips detail the upstream level does not need:

- **S1 → S3** (executor → orchestrator): what shipped, what was
  verified, what surprised, what was left undone, with file:line
  for the change and verification commands run. Not raw diffs,
  not intermediate thinking, not justifications for choices the
  brief already authorized.
- **S3 → S4** (orchestrator → planner): aggregated progress and
  emergent constraints. "Milestone M2 PR-04 to PR-07 are `[x]`
  with caveats {A, B}. PR-08 needs a plan refresh because
  <one sentence>." Not the per-PR completion entries verbatim;
  those live in the archive.
- **S4 → S5** (planner / orchestrator → user): one screen. The
  original goal, the milestones closed, the open questions
  requiring user input (zero or more), the recommended next
  cycle's goal. Hide the cycle bookkeeping; surface only what
  changes the user's mental model or requires a decision.

**Operational rule.** Every channel crossing has a *recipient
capacity budget*. Rough heuristic: `S1 → S3 ≤ one screen of
structured prose per task`; `S3 → S4 ≤ one screen per milestone`;
`S4 → S5 ≤ one screen per session`. If the proposed report
exceeds budget, the orchestrator compresses before forwarding;
if it cannot be compressed without losing fidelity, the original
is archived and only the compressed version travels up.

## The algedonic channel: when to escalate to the user

S5 (user) hears from the loop in only two cases:

1. **Cycle completion.** A goal's outer loop has discharged: the
   ledger is drained for the cycle's scope, the work is
   committed, and the compressed report is ready. This is the
   *expected* channel.
2. **Algedonic escalation.** A subagent or the orchestrator has
   found something the loop cannot resolve. Criteria — all must
   hold:
   - The blocker is **not** a knowledge gap that more research
     could close. If it is, spawn a [[research-loop]] sub-cycle
     first.
   - The blocker is **not** a plan flaw that re-planning could
     fix. If it is, spawn a planner refresh first.
   - The blocker requires a decision only the user can make: an
     architectural commitment with broad implications, a policy
     judgement (risk tolerance, scope cut), a missing external
     input (credential, access, third-party answer), or a
     discovered conflict with `CLAUDE.md` or other
     identity-level rules.

When escalating: one paragraph framing the situation, the exact
question (yes/no, A/B/C, or "please provide X"), the cost of each
alternative if you can characterize them, and a pointer to the
ledger entry. No multi-page recap; the ledger has the detail.

Algedonic must stay rare. A loop that escalates every cycle has
either bad briefing (its plans don't survive contact with
execution) or wrong scope (the goal exceeds the operational
autonomy granted). Diagnose the meta-cause rather than continuing
to escalate.

## Ledgers

Two active ledgers, plus rolling monthly archives, plus a session
log.

### `./tasks.md` — active task ledger

Current goal, current plan, in-progress entries, and recent
completions (last cycle's worth). Mirrors the structure of
[[review-loop]]'s `tasks.md` (Milestones, current PR breakdown,
Cross-cutting architectural notes locked, Completed-recent), with
the addition of a **Cycle** marker at the top so the session
knows which cycle it is in.

**Active-ledger budget:** when nothing is in flight, the active
ledger should fit on one screen. That is S3's working set. Any
detail beyond that goes to archive.

### `./archive/tasks-YYYY-MM.md` — rolling monthly archive

Created on first archival of each month. Append-only. The full
rich entries (what shipped, when, verification commands +
results, surprises, workarounds, constraints future work must
respect) live here. The active ledger only carries a one-line
stub:

```markdown
- [x] **PR-04** — Feature X (archived: archive/tasks-2026-05.md#PR-04)
```

### `./defects.md` — active defect ledger

Schema identical to [[review-loop]]'s `defects.md` (`PR-NN-DMM`
IDs, Status / Severity / Location / Description / Root cause /
Fix). On cycle completion where all defects in a PR group are
`resolved`, migrate that PR's defect section to
`./archive/defects-YYYY-MM.md` with the same stub-and-pointer
pattern.

### `./docs/logs/YYYYMMDD-HHMM-log.md` — session log

Written at session end (cycle completion or algedonic
escalation). One file per session. Captures: goal, cycles run,
what was archived, escalations made, final ledger state. Same
role as in [[review-loop]].

### Why archive instead of "completed-section-grows-forever"

The active ledger is the orchestrator's working set, equivalent
to S3's operational picture. As soon as work is no longer active,
keeping it in the working set is anti-variety: it inflates the
channel capacity needed to load the ledger into context. Archive
is institutional memory at S4 (plannable) and S5 (auditable)
scope, retrieved on demand. This split is the cybernetic analogue
of "current quarter board pack" vs. "historical KPI archive."

## The meta-loop

Two nested loops, like [[review-loop]], but at a higher level of
abstraction.

### Outer loop — goal-to-deliverable

**G1. Receive and clarify the goal (S5 → S4).** The user gives
you the goal. If it has implicit ambiguity (multiple readings,
missing scope boundary, undefined success criterion), do bounded
read-only investigation (grep, file reads, ledger scan) for up
to ~1 minute, then either proceed with a stated reading or batch
the ambiguities via [[question-batch]].

**G2. Form or refresh the plan (S4).**

- **G2a.** Spawn a planning subagent with the goal, in-scope file
  set, relevant ledger state, and `CLAUDE.md` constraints. Ask
  for: milestone breakdown, per-PR breakdown for the current
  milestone, acceptance criteria per PR, risks/assumptions,
  recommended cycle order. The full plan lives in
  `./docs/drafts/YYYYMMDD-HHMM-<name>.md`.
- **G2b.** Spawn an adversarial plan-review subagent (S3\* on the
  plan). Prompt: "find what is wrong with this plan — missing
  milestones, weak acceptance criteria, hidden assumptions,
  mis-sequenced PRs, missing prerequisites." Structured findings.
- **G2c.** Iterate G2a–b until the reviewer accepts, or the loop
  discovers the plan cannot be made acceptable from inside the
  loop → algedonic.
- **G2d.** Commit the accepted plan into `./tasks.md` (the
  active ledger). This is the S4 → S3 transduction: the plan doc
  has full variety; the ledger has the compressed handles for
  dispatch.

**G3. Drive the ledger (S3 inner loop).** See below.

**G4. Compress and deliver (S3 → S5).** When the cycle's ledger
entries are drained (all `[x]` and archived), write the session
log and a one-screen user-facing summary per the variety budget
above. Return control to the user. The session ends here unless
the user gives a follow-up goal.

### Inner loop — driving one ledger entry

For each planned `[ ]` entry in the active ledger:

**I1. Decide cycle type and recursion depth.** Each entry is one
of:

- **Build-style** (writes code, runs tests, ships a PR) →
  delegate to [[review-loop]]'s inner cycle as the primitive.
  Spawn executor, spawn reviewer, iterate.
- **Research-style** (answers a question, produces no code) →
  delegate to [[research-loop]]. The output is an evidence-backed
  ledger entry, not a PR.
- **Substantial** (large enough to be its own viable system) →
  spawn a recursive [[vsm-node]] subagent with its own brief,
  ledger pointer (a subsection of `./tasks.md` or its own ledger
  file), and budget.

The decision is mostly mechanical: a one-day task is build-style;
an open question with multiple plausible answers is
research-style; a multi-cycle deliverable with its own milestones
is substantial. Bias toward the smallest sufficient form;
recursion is overhead.

**I2. Brief, dispatch, await.** Construct the brief per the
*going down* transduction rules above. Spawn the cycle. Await
its compressed return.

**I3. Audit (S3\*).** Even after the sub-cycle's own review
pass, do a brief audit yourself: open the diff or the research
ledger, spot-check one or two claims, confirm the cycle's
report matches the artefact. The audit is **sporadic**, not
exhaustive — that's the point of S3\*. If audit reveals a
discrepancy between report and artefact, the cycle has failed
transduction → re-spawn its review phase with the discrepancy
as input.

**I4. Update ledger and archive.** Flip the entry to `[x]`,
write the rich completion summary, migrate to the month's
archive, leave the one-line stub in `./tasks.md`. Migrate any
resolved defects' PR group to the defect archive. Commit. One
ledger entry = one commit (code + ledger updates).

**I5. Mid-cycle research trigger.** If during I1–I4 a sub-cycle
returns "blocked on missing knowledge" (not a user-facing
blocker — just an unknown), spawn a [[research-loop]] sub-cycle
for that question, fold its findings back into the active plan
or the relevant ledger entry, and resume I2 with the refreshed
brief. This is S3 routing work to S4 mid-execution — exactly
what an adaptive viable system does.

**I6. Mid-cycle replan trigger.** If a sub-cycle returns "the
plan for this entry is wrong given what was discovered" (not
blocked, just wrong), spawn a planner refresh on the affected
scope. Reflect the new plan into the ledger. Do *not* let the
executor improvise around the plan — that breaks the audit trail.

**I7. Cycle blocker.** If a sub-cycle reports a true algedonic
blocker (criteria above), mark the entry `[!]`, record the
blocker in the ledger, and exit to G4 / algedonic escalation.

A clean sub-cycle is not a stop condition for the outer loop. It
ends the inner loop for *this* entry. The outer loop proceeds to
the next planned entry. Returning to the user after one cycle
"because it went well" is the primary failure mode of this skill.

## Composing with `[[review-loop]]` and `[[research-loop]]`

vsm-loop is the **outer** discipline. The two existing loops are
the **specialized inner** disciplines:

- **[[review-loop]]** is the canonical build-style I1 primitive.
  Its inner loop (execute → adversarial review → fix → re-review)
  is the S1 + S3\* pattern for any ledger entry that produces or
  modifies code. Use it verbatim. Its `tasks.md` / `defects.md`
  schema is compatible with vsm-loop's active ledger.
- **[[research-loop]]** is the canonical research-style I1
  primitive. Its hypothesis tree, evidence validation, and DFS
  traversal are S4's epistemic machinery. Use it verbatim. Its
  ledger (`./docs/research/research-<name>.md`) coexists with
  vsm-loop's active ledger; reference it from the relevant
  `tasks.md` entry.

When you invoke one of these from vsm-loop:

- The sub-skill operates within its own loop discipline and
  returns a compressed report to you.
- vsm-loop archives the sub-skill's artefacts and rolls up the
  outcome into the active ledger.
- The sub-skill's stop conditions are the sub-skill's; vsm-loop's
  outer loop continues until *its own* goal is discharged.

## Recursive viability: when to spawn a `[[vsm-node]]`

Spawn a recursive vsm-node when the S1 task itself is large
enough to need its own planning, audit, and ledger — e.g.
"implement subsystem X" where X is itself worth a milestone
breakdown. The subagent:

- Receives a self-contained brief (your S3 → its S5).
- Maintains its own ledger subsection under `./tasks.md` (or its
  own ledger file if the work is large; the brief specifies).
- Runs its own outer/inner cycles using vsm-loop discipline.
- Reports compressed results back to you, with algedonic channel
  open to escalate to **you** (not directly to the user).
- You decide whether its escalations propagate further up.

This is Beer's recursion principle: each S1 contains its own
S1–S5. The escalation chain is layered — a leaf subagent's
algedonic goes to its immediate parent, which either resolves it
(re-plans, re-briefs) or propagates upward, possibly all the way
to the user.

Do **not** spawn a recursive vsm-node for tasks that fit cleanly
into [[review-loop]] or [[research-loop]]. The recursion overhead
must be earned.

## Subagent briefing under VSM

Each brief is the explicit transduction from your S3 into the
subagent's S5. It must contain:

1. **Identity / scope** — who this subagent is in the hierarchy.
   "You are a build-cycle subagent operating at level N+1; parent
   is the main vsm-loop orchestrator." For recursive nodes, also
   the [[vsm-node]] reference.
2. **Goal** — the unit deliverable, one sentence. This is the
   subagent's S5.
3. **Acceptance criterion** — operational, testable. "Command X
   exits 0; file Y contains pattern Z." This is what your audit
   will check.
4. **Scope envelope** — explicit in/out: which files may be
   edited, which may only be read, which are off-limits.
5. **Context excerpt** — the relevant slice of the plan, prior
   ledger entries, or research findings. Not the whole ledger;
   the slice this cycle needs.
6. **Recursion permission** — whether the subagent may spawn its
   own subagents (per [[vsm-node]]) and under what conditions.
   Default: no — only spawn for sub-tasks that meet the
   substantial threshold.
7. **Report contract** — what the subagent's compressed return
   must contain (deliverable, verification commands + results,
   surprises, anything left undone, algedonic flag if blocked).
   Reject vague returns.

A brief that fails: "do the next task in the plan." That pushes
both expansion and synthesis onto the subagent, which has neither
the context nor the authority.

## Parallelism and S2 anti-oscillation

S2's job is to keep parallel S1s from clobbering each other. The
discipline from [[review-loop]] applies verbatim:

- **Use the Agent tool's `isolation: "worktree"`** for every
  concurrent editor. Read-only subagents share the main
  checkout.
- **Never script worktree lifecycle by hand.** Briefs never
  mention `git worktree`, `cd`, or `rm`.
- **Merge back deterministically.** The orchestrator merges in a
  defined order.
- **Serial when the work doesn't partition.** Sub-tasks that
  touch the same file or build on each other's output run
  serially.

vsm-loop adds two S2 rules of its own:

- **One active cycle per ledger group at a time.** Two parallel
  S1s on the same `./tasks.md` PR group corrupts the audit trail
  even with worktrees, because the ledger updates collide.
  Parallelise across PR groups, serialise within.
- **Recursive vsm-node subagents get their own ledger
  subsection or file.** Their internal cycles don't write to the
  parent's `./tasks.md` directly; they report to the parent,
  which integrates the compressed result.

## Model selection per VSM role

Loop quality is dominated by S4 (planning, research) and S3\*
(audit, review). A weak S1 wastes a cycle; a weak S3\* ships a
defect; a weak S4 leads the whole loop in the wrong direction.

Defaults, overridable when a task warrants it:

- **S4 (planning, research) subagents** — strongest available
  reasoning model with the largest context. The plan must hold
  the goal, the ledger, and cross-cutting decisions
  simultaneously.
- **S3\* (audit, review) subagents** — same. Adversarial review
  is exactly where a weaker model regresses to surface checks.
- **S1 (execution, fix) subagents** — Sonnet-class default. Most
  S1 work is mechanical once the brief is good. Escalate to a
  stronger model for S1 tasks that are design decisions in
  disguise.
- **S3 (orchestrator — you), S2 (ledger maintenance), S5
  (escalation drafting)** — orchestrator model, no subagent.

Two non-negotiable rules:

- **Never downgrade S4 or S3\* to save cost.** Missed plan
  branches and missed defects compound across cycles.
- **Name the model in the brief** when it differs from the
  parent's. A weaker subagent that discovers its task needs
  design judgement should return with a written question rather
  than improvise.

## What lives where

- `./tasks.md` — active task ledger (S3's working set).
  Checked in.
- `./defects.md` — active defect ledger. Checked in.
- `./archive/tasks-YYYY-MM.md` — completed tasks, rolling monthly
  archive. Checked in.
- `./archive/defects-YYYY-MM.md` — resolved defects, rolling
  monthly archive. Checked in.
- `./docs/drafts/YYYYMMDD-HHMM-<name>.md` — per-cycle plan docs.
  Checked in.
- `./docs/logs/YYYYMMDD-HHMM-log.md` — one file per session.
  Checked in.
- `./docs/research/research-<name>.md` — research-loop ledgers
  referenced from `./tasks.md`. Checked in.
- Code changes — as normal.
- Nothing transient (intermediate subagent transcripts, drafts
  the orchestrator rejected, partial plans superseded by a
  refresh) needs to survive. The ledgers, archives, and log are
  the record.
