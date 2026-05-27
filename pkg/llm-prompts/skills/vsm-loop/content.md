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

## When to invoke vsm-loop

This skill carries real overhead — a planning subagent, an audit
pass, ledger discipline, and a recursion contract. Invoke it when
**all three** hold:

1. **Plan-the-plan is itself a deliverable.** The user's request
   is open enough that producing the milestone breakdown is real
   work, not a paragraph.
2. **At least one S1 cycle will spawn its own sub-cycles.** The
   work will recurse — sub-tasks substantial enough to need their
   own planning and audit, per [[vsm-node]].
3. **Multiple decision points the orchestrator cannot
   pre-resolve.** During execution, the loop will discover
   constraints that change the plan, not just refine it.

If only one or two hold, prefer [[review-loop]] alone (build-style
work) or [[research-loop]] alone (investigation). The meta-overhead
of vsm-loop is paid back by reduced rework on genuinely large
tasks; on small ones it taints perceived value.

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
  against S4, holds the system's identity. S5 is **internal** to
  the viable system; the level above it is the *metasystem* in
  which the viable system is embedded.

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
| **Metasystem** | Commissioning authority, identity-level rules above the viable system | User + project constitution: `CLAUDE.md`, `AGENTS.md`, explicit user instructions, safety/security policy, the "what must always be true" the system inherits from outside. |
| **S5** | Holds the system's identity; balances S3 against S4 | The orchestrator's commitment to translate metasystem intent into operational policy and enforce identity rules (security, safety, scope, non-negotiables). |
| **S4** | Plans, researches, models | Planning subagents; [[research-loop]] invocations; design-deliberation subagents. |
| **S3** | Allocates work here-and-now; regular oversight | Main session as orchestrator: dispatches subagents, maintains ledgers, decides parallelism, sequences cycles. Includes the structured per-cycle review channel ([[review-loop]] I2) — that is S3 oversight via the S2 ledger/diff channel, *not* S3\*. |
| **S3\*** | Sporadic, direct audit of S1 that bypasses S2 | Orchestrator's spot-checks during vsm-loop I3: open the diff or research artefact, verify one or two claims against source, confirm the cycle's report matches reality. Sporadic by design — exhaustive audit collapses back into S3. |
| **S2** | Anti-oscillation between parallel S1s; *automatic*, non-managerial coordination | Two parts: (a) **transversal conventions** — sequential defect IDs, sequential PR IDs, ledger-entry-per-cycle, naming schemes for plan docs and archives, fixed report shapes. These let parallel S1s avoid collision without S3 intervention. (b) **Workspace isolation** — worktree-per-editor, one-cycle-per-ledger-group, parallel-vs-serial discipline. The ledger format is S2's substrate (the conventions all S1s read and write through) but the *content* of the active ledger is S3's institutional memory. |
| **S1** | The actual work | Execution subagents (code, tests, edits). For substantial S1 tasks, the subagent runs its own vsm-loop per [[vsm-node]]. |

The S1 units in this mapping are themselves viable systems
internally: an execution subagent that gets a non-trivial task
spawns its own planner, executor, and reviewer, with its own S5
(its brief), its own S2 (its ledger subsection), and its own
escalation channel back up to its parent. Recursion is bounded —
at the leaves, the work is atomic and the subagent simply does it.

## Non-negotiable rules

- **You (the main session) operate at S3/S2 and hold the
  orchestrator's own S5 commitment, with S3\* audit authority.**
  You do not perform primary execution, primary research, or detailed
  planning yourself; those phases run in subagents. You may validate
  cited artefacts, inspect samples, re-run checks, and compare reports
  against diffs/ledgers as S3\* audit. You translate metasystem intent
  (user + project constitution) into operational policy; you do not
  invent new metasystem policy.
- **The brief is the resource bargain.** In Beer's terms, the
  brief between S3 and S1 (or between any level and its
  subordinate) is a negotiated envelope of scope, budget, and
  autonomy: inside the envelope the subagent acts; outside it
  returns or escalates. Violating the bargain — editing outside
  the scope, expanding the goal, returning raw output without
  compression — is a structural failure, not a stylistic one.
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
  `./docs/archive/tasks-<milestone-id>.md` with a one-line stub left in
  `./tasks.md`. Never delete; only flip state, append, or migrate.
- **Subagents are locally autonomous within their brief.** You
  set the goal, the success criteria, the file scope, and the
  recursion permission. Inside that envelope, the subagent
  decides how to do the work and what intermediate steps to
  take. Do not micromanage; do audit.
- **Algedonic is rare and structured.** A subagent raises an algedonic
  flag to its parent only when the brief cannot be discharged from
  inside the loop *and* the resolution requires authority above the
  parent: missing credential, contradictory requirement, architectural
  choice needing user input, safety/security finding requiring policy
  judgement. Only the top-level orchestrator crosses the *metasystem
  boundary* (to the user + project constitution); intermediate
  layers resolve algedonic from inside the orchestrator's own S5
  whenever `CLAUDE.md` + the brief is sufficient. Everything else
  stays in the loop — including "I'm stuck" (route to S4 / more
  research) and "this is harder than estimated" (route to S4 /
  replan).
- **One ledger entry = one S1 cycle = one commit.** S2
  discipline. Cycles that bleed into each other corrupt the
  audit trail.

## Stop conditions: when (and only when) the loop emits user-facing text

The loop emits user-facing text on exactly **two** triggers:

1. **G4 — ledger drained.** All planned entries in the active
   ledger are `[x]` and archived; defects are closed or migrated;
   the cycle's commits are made; the compressed summary is ready.
2. **Algedonic escalation across the metasystem boundary.** A
   blocker meeting all three criteria in § *The algedonic channel*
   has been raised and the orchestrator's own S5 cannot resolve
   it.

A third trigger — **explicit user stop** — overrides the loop:
if the user types something that *unambiguously* halts the work
("stop", "pause", "halt", "abort", "we're done", "let's stop
here"), end the cycle. A user message that is *not* an explicit
stop — a clarifying question, a side-question, a correction, a
new constraint, a piece of context, a redirect within the same
goal — does **not** end the loop. Answer the question or absorb
the input, then resume the next ledger entry without asking
permission. Treating every user message as an implicit "stop" is
the symmetric failure of the courtesy-checkpoint pattern: it
converts a question into an unsolicited handoff. If the user's
message is ambiguous between "answer and continue" and "stop",
ask which — but the default reading of a non-stop message is
*continue*.

Everything else is **not** a stop condition. In particular, the
following are *not* triggers for emitting user-facing text:

- A clean inner-loop cycle finished. (This is G3 → next entry,
  not G4.)
- A milestone closed but other milestones remain in the ledger.
- The work feels like a "natural checkpoint" or a "good place to
  pause."
- The next milestone is "trickier" or "design-heavy" and you
  would feel better with the user reviewing first.
- Commits are made and you want to "give the user a chance" to
  review or push them.
- You are uncertain whether the user wants you to continue.

If you are uncertain whether the user wants you to continue, the
brief already answered: **continue.** The brief that invoked
vsm-loop is durable authority for the whole goal, not for one
cycle. Re-confirming each cycle is the exact failure mode this
discipline exists to suppress.

### Pre-flight check before any mid-loop user-facing text

Before emitting *any* text to the user while the ledger is not
drained, run this check. If you are about to write any of the
following phrases — or anything paraphrasing them — **stop and
continue the loop instead**:

- "natural checkpoint" / "good checkpoint" / "clean handoff"
- "pausing here" / "stopping here" / "taking a break here"
- "would you like me to…" / "should I…" / "do you want me to…"
- "shall I continue" / "ready for me to proceed"
- "(a) … / (b) … / (c) …" menus of options
- "the working tree is clean and the suite is green, so…"
- "state is stable for either decision"
- "this is a natural place to…" / "this is where the skill says
  S4 earns its keep, so…"
- Any framing that offers the user a choice between *continue*
  and *stop* when the brief already authorized *continue*.

These phrases are not neutral status updates. They are RLHF-
induced solicitations of approval, and they convert durable
authority into per-cycle re-authorization, which is exactly what
the resource bargain rules out. The correct mid-loop emission
volume is **zero text**. Run the next cycle.

The check applies regardless of how well the cycle went, how
"tricky" the next entry looks, or how courteous the
checkpoint-offer would feel. Courtesy is not a stop condition.

### Failure mode: courtesy checkpoint

**Symptom.** Orchestrator returns to the user after a clean
cycle with a status report and a menu of options ("continue /
pause / push"), framed as a courtesy or a "clean handoff."

**Cause.** The model's trained helpfulness reflex (RLHF rewards
mid-task check-ins) overrides the skill's durable-authority
contract. The loop is not actually blocked — it has a clear next
entry and a clean working tree. The "checkpoint" is invented.

**Why it matters.** Every such emission is a *false algedonic* —
indistinguishable to the user from a real one, but with no
underlying blocker. It trains the user to discount the loop's
escalations, costs their attention budget, and breaks the
audit-trail contract that says the user-facing channel carries
only G4 reports and real escalations.

**Counts as.** A non-credential ordinary algedonic for metric §7
(a false positive against the frequency threshold). Diagnose the
same way: bad brief? unclear authority? scope creep? If none,
it is reflex-failure; the corrective action is to continue
immediately and note the near-miss in the session log.

**Control action.** If you catch yourself mid-emission, delete
the draft and run the next cycle. If the emission has already
left your output, your next action on the user's next turn is to
continue the loop without further preamble — do not apologise,
do not re-justify, do not narrate the recovery. Each of those
compounds the variety leak.

## Variety engineering: the transduction discipline

The single most common failure mode of multi-agent orchestration
is *variety mismatch*: too much detail at a level that needed a
summary, too little detail at a level that needed a brief.
Operationally:

**Going down (S5 → S4 → S3 → S1) — amplification.** Amplification
has two faces. **Expand**: specify the paths, examples, acceptance
criteria, and context the downstream level needs to discharge the
brief. **Constrain**: close off the solution space — "do not
introduce new dependencies", "edit only these files", "do not
refactor adjacent code". Both are amplification of *control*:
expansion gives the subagent enough state to act; constraint
removes states it should not enter. A brief that only expands
typically produces over-scoped work; one that only constrains
without expanding produces stuck work. Every channel crossing
should do both.

Each channel adds specificity the downstream level needs to act:

- **S5 → S4** (user / project constitution → planner): goal +
  non-negotiables + in/out of scope + budget constraint. The
  orchestrator transduces the user's request and standing project
  policy into this planning brief; it does not create new policy. The
  planner expands the brief into a milestone breakdown, PR sequence,
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

## The S3-S4 homeostat

Beer's central cybernetic loop: S3 ("inside-and-now") and S4
("outside-and-future") are coupled, with S5 holding the balance.
Operationally, this homeostat fires whenever execution exposes
information the plan did not model.

- **S3 → S4 firing** — a sub-cycle returns "blocked on missing
  knowledge", "the upstream API behaves unexpectedly", or "the
  plan for this entry is wrong given what was discovered". The
  orchestrator routes to S4 (a [[research-loop]] sub-cycle or a
  planner refresh) before another execution round. This is I5
  and I6 of the inner loop.
- **S4 → S3 firing** — S4 returns a refreshed plan or validated
  research result; S3 reflects it into the active ledger and
  resumes dispatch.
- **Stable state** — the next sub-cycle returns clean against
  the refreshed plan.

These triggers are not exceptional events. They are the
homeostat doing its job: in a viable system the inside-now and
outside-future loops must oscillate as the environment reveals
itself. A loop that *never* fires its homeostat is suspicious —
either the plan was prescient or the executor is ignoring its
brief.

### When the homeostat should *not* fire

A loop that fires its homeostat on every drift is as broken as
one that never fires. Most plan-vs-reality gaps are leaf-level
refinement, not S4 territory. Distinguish:

- **Refinement (no firing).** The executor touched a planned
  file in a way the plan did not enumerate line-for-line; the
  acceptance criterion was met by a slightly different path; a
  test required a one-line setup the plan did not name; a
  variable name changed during implementation. These do not
  invalidate the plan; they fill in detail the plan deliberately
  left to the leaf. Report the result in the *Surprises* line of
  the subagent return; do not fire I5 or I6.
- **Uncovered structure (fire S4).** Execution revealed a new
  dependency, an upstream API behaves differently from the
  plan's model, a constraint exists that the plan did not see,
  the brief's acceptance criterion is impossible without
  modifying scope. The plan's *model* of reality is wrong, not
  just its detail. Route to S4 (I5 or I6).

The test: would a different leaf executor have hit the same
issue? If yes, fire S4 — the issue is structural, in the plan's
environmental model. If no, the issue is local to this execution
and is leaf-level refinement.

A second test: did the brief's acceptance criterion still apply
verbatim? If yes, no firing. If the executor had to *redefine*
the acceptance criterion to discharge the brief, fire S4 — the
plan's reading of the goal was wrong.

### Failure mode: homeostat thrashing

Repeated firing on one entry without convergence — research routes
back to plan, plan back to execution, execution back to research,
with no clean return. When this happens, the cause is upstream,
not in the current cycle:

- S4's environmental model is stale (the planner is working from
  outdated assumptions).
- S5 policy is over-constrained (no plan can satisfy both the
  brief and the non-negotiables).
- The entry's scope was mis-bounded (the work crosses a fault
  line the plan didn't see).

Diagnose the meta-cause: re-seed the planner with fresh
environmental observations, route a clarifying question to the
metasystem (algedonic), or re-partition the entry. Do not keep
oscillating.

## Control metrics: viability signals

These are control metrics, not productivity metrics. Their purpose is
to detect loss of viability: too much work in flight, weak
transduction, bad plans, weak review, or excessive escalation. Track
them in `./tasks.md`, `./defects.md`, and the session log only where
the signal affects a control decision.

A note on lineage: the WIP / review / scope metrics below are
operational signals drawn from lean and agile traditions — they
are cybernetic in spirit but not Beer's. The genuinely Beer
metrics are the homeostat-pulse signals (§12–14) and algedonic
frequency (§7–8): they directly measure the system's adaptive
behaviour rather than its throughput.

### Required metrics

1. **WIP load** — count `[~]` task entries, active subagents, and
   concurrent editors.
   - Threshold: one active cycle per ledger group; parallel editors
     only when write scopes are disjoint.
   - Control action: serialise conflicting work; do not spawn more
     editors until WIP returns inside the threshold.
2. **Review churn** — review rounds per PR/task and defects found per
   round.
   - Threshold: a third review round with major or minor findings.
   - Control action: route to S4 for replan or scope correction before
     another fix round.
3. **Defect recurrence** — repeated defect class across PRs or across
   review rounds.
   - Threshold: same class appears twice in one milestone.
   - Control action: record a cross-cutting architectural note or open
     a [[research-loop]] question.
4. **Verification coverage** — every completed PR/task has exact
   verification commands and results.
   - Threshold: missing command result on a completed entry.
   - Control action: the entry cannot close; run verification or mark
     the entry blocked with the missing precondition.
5. **S3\* audit discrepancy rate** — spot-checks where the report,
   diff, ledger, or cited source do not match.
   - Threshold: any discrepancy in the current cycle.
   - Control action: re-open review for that cycle. Two discrepancies
     in one milestone trigger a brief/report-contract correction.
6. **Transduction failure rate** — subagent returns too verbose, too
   vague, missing paths, missing verification, or raw uncompressed
   output.
   - Threshold: two failed reports from the same loop type in one
     milestone.
   - Control action: revise that loop's brief template before
     continuing.
7. **Algedonic frequency** — user escalations per milestone, grouped
   by reason and by channel (ordinary / bypass / depth-limit), and
   cross-tabulated against the user-verdict captured at resolution
   time (legitimate / false-positive / unclear / deferred — see the
   "Capturing the user verdict" subsection in the algedonic
   section).
   - Threshold: more than one non-credential ordinary escalation in
     one milestone; any bypass false-positive (see §8); any
     `unclear` verdict on a non-trivial escalation.
   - Control action: diagnose bad scope, missing S5 policy, or weak S4
     planning before continuing.
8. **Bypass false-positive rate** — count of `BYPASS`-flagged
   algedonic that the user later judged were not policy
   violations (`user-verdict=false-positive` from the capture
   step). Tracked because the must-propagate-unchanged contract
   makes bypass a high-stakes channel: a noisy subagent that
   raises bypass on ordinary blockers trains the user to discount
   the channel, defeating its purpose.
   - Threshold: any bypass false-positive.
   - Control action: review the brief and the subagent's
     reasoning together; tighten the bypass criteria in the brief
     template, or escalate to S4 to refine when subagents should
     reach for bypass vs ordinary algedonic. A single false
     positive is enough to act on — bypass earns its weight by
     being rare.
9. **Blocked age** — age of `[!]` task entries in sessions.
   - Threshold: blocked entry older than one session.
   - Control action: resolve, rescope, explicitly defer, or escalate.
     Do not let blocked entries accumulate silently.
10. **Archive pressure** — active ledger length when nothing is in
    flight.
    - Threshold: active `./tasks.md` no longer fits roughly one screen.
    - Control action: archive closed milestone material under
      `./docs/archive/`.
11. **Plan accuracy** — planned file/scope boundaries versus actual
    touched files, defects, and follow-up tasks.
    - Threshold: repeated scope expansion in one milestone.
    - Control action: route to S4; the plan underestimated variety.
12. **Homeostat firings (S3↔S4)** — count of research triggers
    (I5) and replan triggers (I6) per ledger entry, tracked
    separately. **Counting rule**: only events that pass the
    "should the homeostat fire?" test above count toward this
    metric. Refinement-class drift reported in a subagent's
    *Surprises* line does **not** increment the counter, because
    it did not actually fire the homeostat; it was absorbed at
    S1. Counting refinements would let careful executors who
    surface detail look worse than careless ones who suppress it.
    - Threshold: more than two firings of either type on a single
      entry; or three combined across types on one entry.
    - Control action: diagnose which of three upstream causes is
      active and address it directly — (a) **stale S4 model**:
      re-seed the planner with fresh environmental observations
      from this cycle; (b) **over-constrained S5 policy**: route
      a policy clarification through algedonic to the metasystem;
      (c) **mis-bounded entry**: re-partition the entry along the
      fault line the execution exposed. Do not fire the homeostat
      a fourth time without naming the cause.
13. **Time to stabilize** — number of sub-cycles between a
    homeostat firing and the next *clean return* (a sub-cycle
    that returns its compressed report without raising another
    homeostat firing or an algedonic flag). Tracked per firing
    type.
    - Threshold: more than two sub-cycles to stabilize on a
      single firing.
    - Control action: the refreshed plan or research result is
      also wrong relative to reality; re-seed the planner with
      observations from the *failed* refresh round, or
      re-partition. Do not request a third refresh on the same
      framing.
14. **Material scope delta** — closed-entry actual scope vs
    planned scope (files touched, follow-ups opened). Drift that
    is pure leaf-level refinement (touching a planned file in a
    way the plan did not enumerate line-for-line) is **not**
    material; *uncovered* work (new files not in the plan, new
    follow-up tasks, new defects in unplanned areas) **is**
    material.
    - Threshold: material delta on two consecutive entries in
      one milestone.
    - Control action: route to S4; the planner is under-modelling
      variety in the current area. Pure refinement deltas are
      normal and not a trigger.

### Minimal dashboard

At session end, include a compact metrics line in
`./docs/logs/YYYYMMDD-HHMM-log.md`:

```markdown
Metrics:
- WIP max <n>; review rounds <PR-01:n, PR-02:n>
- S3-S4 firings <research:n, replan:n>; time-to-stabilize <research:max, replan:max>
- Material scope delta <none|summary>; verification <complete|gaps>
- Audit discrepancies <n>; algedonic <ordinary:n, bypass:n, depth-limit:n>; bypass false-positives <n>
```

The four-bullet form is the canonical layout — a single-line
form would exceed the one-screen budget once all counters are
included. Track `depth-limit` separately from ordinary algedonic
and bypass per [[vsm-node]] § *Recursion-depth bound*.

Only expand beyond that line when a threshold fired. The control action
belongs in the ledger entry or session log next to the metric that
triggered it.

## Environment channels: outside and future

VSM distinguishes the system from its environment. In this workflow,
the environment includes the repository, tests/CI, runtime/tooling,
upstream documentation and APIs, external systems, user constraints,
security/operations context, and future maintenance pressure.

- **S1** interacts with the immediate operational environment: files,
  tests, builds, local services, and generated artefacts.
- **S4** scans outside-and-future context: upstream docs, API changes,
  architectural alternatives, long-term risks, migration paths, and
  uncertainty that current execution exposed.
- **S3** reconciles current capability with S4's environmental model:
  it updates the active plan, changes sequencing, allocates work, or
  routes back to S5 when policy authority is required.
- **S5** supplies identity and policy constraints: which risks matter,
  which tradeoffs are acceptable, what must never be violated.

Do not treat the codebase as the whole environment. If execution
uncovers dependency drift, external API ambiguity, CI/runtime mismatch,
security exposure, or a maintenance constraint, route the question to
S4 before continuing operational work.

### S1's local environment loop

A subagent does **not** need to escalate every interaction with
its local environment back through S3. Each S1 unit is itself a
viable system embedded in its own piece of the world, and Beer's
model gives it authority to close its own loop locally.

**Whose authority is this?** The local-loop authority belongs to
the *leaf executing subagent* — the level that actually runs
tests, edits files, probes services. It does **not** extend to
orchestrators at any layer. The main session running [[review-loop]]
or vsm-loop is an orchestrator, not a leaf, even when the
orchestrator itself is the S1 of a parent vsm-loop. Orchestrators
dispatch and audit; they do not iterate against the local
environment themselves. The "never edit yourself, even trivial"
rule in [[review-loop]] is the orchestrator-side counterpart of
this rule: leaves iterate locally, orchestrators do not.

Concretely: inside the scope envelope set by the brief, the
subagent is authorized to iterate against:

- The test suite (run, observe failure, edit, re-run).
- The build (compile, type-check, lint, fix, repeat).
- A REPL or local service (probe, observe, adjust).
- The filesystem within the write scope.

These local-loop iterations are **S1's own homeostat**, not S3-S4
firings. The subagent does not report each iteration; it reports
the *converged* result (or non-convergence as *left undone*).

Escalate to S3 only when the local loop fails to converge inside
the budget the brief authorized, or when the loop reveals
something the brief did not anticipate (an unrelated regression,
an upstream change, a missing dependency). The cost of
*not* granting this autonomy is that S3 saturates on iteration
detail; the cost of granting too much is that subagents
silently improvise outside scope. The scope envelope is what
keeps the autonomy bounded.

This is implicit in Beer's recursion (each S1 contains its own
S1–S5), but worth naming because agentic systems frequently
either over-report (every test run surfaces to the orchestrator)
or under-bound (subagents iterate themselves into unrelated
parts of the tree). The fix is *bounded autonomy*: explicit
local-loop authority inside an explicit envelope.

## The algedonic channel: when to cross the metasystem boundary

The user and `CLAUDE.md` form the *metasystem* above this viable
agent system. Algedonic that terminates inside the orchestrator's
own S5 (a policy call the orchestrator can resolve from `CLAUDE.md`
+ the brief) is normal and does not need to surface. Algedonic
that **crosses the metasystem boundary** — reaching the user
directly — is what this section covers.

### Deviation from canonical Beer: a deliberate tradeoff

The single largest deviation from Beer's classical VSM in this
framework lives here, and the reader should not skim past it.

In Beer's canonical model, the algedonic channel **bypasses the
chain**: a pain signal goes from *any* S1 directly to S5, without
intermediate filtering. This is the body-analogue: pain receptors
in your hand do not consult your elbow before firing your cortex.

This framework deliberately narrows that. The default discipline
is that algedonic walks the parent chain, and each layer's S5
gets to resolve from `CLAUDE.md` + the brief before propagating
further. The reason is operational safety in an agentic context:
unrestrained S1→user bypass turns every confused leaf subagent
into a user interrupt, which destroys both the orchestrator's
audit trail and the user's attention budget.

The cost of this narrowing is real: a leaf subagent that genuinely
detects a policy violation cannot phone home directly. To preserve
the *substantive* function of Beer's bypass (the carve-out for
identity-threatening signals), the framework reintroduces a
restricted bypass in [[vsm-node]]'s *Bypass authority* subsection:
a `BYPASS`-flagged algedonic that the parent **must** propagate
upward unchanged, with no opportunity to re-litigate. This covers
the genuine policy-violation case — credentials, security gates,
identity rules from `CLAUDE.md`, and operational-policy gates the
metasystem has marked non-negotiable (immutable data, required
CI/CD checks, mandatory audit trails) — while keeping the
ordinary "I'm stuck" / "the plan is wrong" path inside the loop.
See [[vsm-node]] § *Bypass authority* for the full criteria; the
two files use the same list.

If you find yourself reaching for ordinary algedonic frequently,
the loop has a deeper problem (bad scope, bad plan, weak briefs);
diagnose the meta-cause rather than escalating each instance.

### The two channels to the metasystem

The user-facing metasystem hears from the loop in only two cases:

1. **Cycle completion.** A goal's outer loop has discharged: the
   ledger is drained for the cycle's scope, the work is committed, the
   compressed report is ready, and any metric threshold that fired has
   a recorded control action. This is the *expected* channel.
2. **Algedonic escalation across the metasystem boundary.** A
   subagent has raised an algedonic flag through its parent chain
   and the orchestrator's own S5 cannot resolve it; or the
   top-level orchestrator has found something the loop cannot
   resolve from `CLAUDE.md` + the brief. Criteria — all must hold:
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

### Capturing the user verdict (closes the §8 loop)

When the user resolves an algedonic escalation, the orchestrator
**must** record the user's judgement in the session log alongside
the original escalation entry, in a fixed shape:

```markdown
Escalation <id>: channel=<ordinary|bypass|depth-limit>;
  user-verdict=<legitimate|false-positive|unclear|deferred>;
  notes=<one line, optional>.
```

- For **ordinary** algedonic the verdict feeds metric §7 (frequency
  by reason).
- For **`BYPASS`** algedonic the verdict feeds metric §8 (false-
  positive rate). Without this capture step §8 has no data; do
  not omit it.
- For **`DEPTH-LIMIT`** the verdict captures whether the user
  agreed the plan needed replanning at that depth or judged the
  subagent could have absorbed the work — useful signal for
  recursion-permission tuning.

The verdict is recorded by the orchestrator at the moment the
user's response arrives, not deferred to session end (deferral
loses fidelity). If the user does not state a verdict explicitly,
infer it from their response and mark `unclear` if genuinely
ambiguous; do not default to `legitimate`.

Algedonic must stay rare. A loop that escalates every cycle has
either bad briefing (its plans don't survive contact with
execution) or wrong scope (the goal exceeds the operational
autonomy granted). Diagnose the meta-cause rather than continuing
to escalate.

## Ledgers

Two active ledgers, plus per-milestone archives, plus a session
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

### `./docs/archive/tasks-<milestone-id>.md` — per-milestone task archive

Created when a milestone first archives completed task entries.
Append-only. The full
rich entries (what shipped, when, verification commands +
results, surprises, workarounds, constraints future work must
respect) live here. The active ledger only carries a one-line
stub:

```markdown
- [x] **PR-04** — Feature X (archived: ./docs/archive/tasks-M1.md#PR-04)
```

### `./defects.md` — active defect ledger

Schema identical to [[review-loop]]'s `defects.md` (`PR-NN-DMM`
IDs, Status / Severity / Location / Description / Root cause /
Fix). On cycle completion where all defects in a PR group are
`[x] resolved`, migrate that PR's defect section to
`./docs/archive/defects-<milestone-id>.md` with the same stub-and-pointer
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

**G0. Carryover audit (when the session resumes from a compacted
context).** If this invocation is a continuation rather than a
fresh ask, do NOT trust the carryover summary's "open follow-ups"
/ "deferred items" lists at face value. The summary is a snapshot
from the moment of compaction; ledger writes between that moment
and now are not back-propagated into it, and lists generated
early in the original session may not reflect work the later
cycles already closed.

Recognition signals that this turn is a continuation: the first
user-turn content reads as a third-person recap of prior cycles;
it names ledger entries, PR IDs, or defects you have no memory
of spawning; or it matches the harness's compaction header /
"Previous conversation summary" framing.

When recognized, before planning any cycle:

1. Open `./tasks.md` and `./defects.md` (and their archives if
   the summary names defects whose milestone is closed).
2. For each follow-up the summary names, verify its current
   status in the ledger. Drop anything `[x] resolved`. Verify
   the cited source location still exists and the cited
   behaviour still holds.
3. Reconcile silently when the discrepancies are small; if more
   than two follow-ups in the summary are stale, raise an
   algedonic flag to the user — the upstream summary discipline
   failed and the lapse is worth surfacing, not just patching
   over.

This is the S3\* discipline applied to the carryover snapshot
itself. Skipping G0 makes you plan cycles for work that is
already done; the cost is one full audit pass before discovery.

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
above. The session log MUST include a "Resolved this session"
subsection enumerating each defect ID + closing commit (e.g.
`PR-M12-03-D01 → commit abc1234`); this is what G0 of the *next*
session reads when reconciling the inherited carryover snapshot,
so the lookup is O(grep) instead of O(re-audit). This complements
rather than replaces the per-milestone defect archive — the
archive is the canonical record, the session-log subsection gives
G0 a session-local index so it does not need to know which
milestone owns the defect. Return control to the user. The
session ends here unless the user gives a follow-up goal.

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
write the rich completion summary, migrate to the milestone's
archive, leave the one-line stub in `./tasks.md`. Migrate any
resolved defects' PR group to the milestone defect archive. Commit. One
ledger entry = one commit (code + ledger updates).

**I5. Mid-cycle research trigger (S3 → S4 homeostat firing).** If
during I1–I4 a sub-cycle returns "blocked on missing knowledge"
(not a user-facing blocker — just an unknown), spawn a
[[research-loop]] sub-cycle for that question, fold its findings
back into the active plan or the relevant ledger entry, and
resume I2 with the refreshed brief. This is S3 routing work to
S4 mid-execution — the homeostat doing its job. Count this
firing; see §12–13.

**I6. Mid-cycle replan trigger (S3 → S4 homeostat firing).** If
a sub-cycle returns "the plan for this entry is wrong given what
was discovered" (not blocked, just wrong), spawn a planner refresh
on the affected scope. Reflect the new plan into the ledger. Do
*not* let the executor improvise around the plan — that breaks the
audit trail. Count this firing; if I5+I6 exceed the threshold on
one entry, diagnose upstream per the homeostat section.

**I7. Cycle blocker.** If a sub-cycle reports a true algedonic
blocker (criteria above), mark the entry `[!]`, record the
blocker in the ledger, and exit to G4 / algedonic escalation.

**Inner-loop completion → unconditionally proceed to next ledger
entry.** No status update to the user. No offer. No
acknowledgement that a cycle finished. The next user-facing
emission is G4 (ledger drained) or an algedonic that meets all
three criteria — nothing else. See § *Stop conditions* for the
closed list and the phrase-detector; *Returning to the user
after one cycle "because it went well" is the primary failure
mode of this skill*, and the most common surface of it is the
courtesy-checkpoint pattern catalogued there.

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
subagent's S5 — and it is the **resource bargain** between you
and the subagent: a negotiated envelope of scope, budget, and
autonomy. Inside the envelope the subagent acts; outside it
returns or escalates. The brief must contain:

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

S2's job is to keep parallel S1s from clobbering each other —
*automatically*, without S3 having to mediate every interaction.
Beer's analogue is the sympathetic nervous system: it coordinates
the body's organs through standing reflexes, not through cortical
attention. This section is the **canonical home** for both faces
of S2: transversal conventions and parallel-editor discipline.
[[review-loop]] and [[vsm-node]] reference it for runtime-specific
guidance.

### Transversal conventions (the standing reflexes)

These are the rules every S1 subagent inherits through the brief
and the ledger schema, with no per-cycle negotiation:

- **Sequential, never-reused IDs.** Defect IDs (`PR-NN-DMM`),
  PR IDs, milestone IDs, archive filenames are all assigned in
  monotonically increasing order and never reused even after a
  defect is resolved or a PR is reverted. Two parallel subagents
  cannot collide on an ID because they never both pick the next
  one — the orchestrator hands them out.
- **One ledger entry = one cycle = one commit.** A standing
  reflex that prevents two cycles from blending into one
  uncommittable mass.
- **Append-only ledgers.** Subagents may *propose* state
  transitions in their report; only the orchestrator flips
  status. This eliminates write-conflict races on the ledger.
- **Fixed report shape** (deliverable / verification / surprises /
  left undone / algedonic). Two parallel subagents return
  comparable reports; the orchestrator does not have to
  reverse-engineer each one.
- **Per-subagent worktree paths** assigned by the orchestrator,
  not chosen by the subagent. No two subagents can race on the
  same checkout because the namespace is allocated up front.

Transversal conventions matter because they let the orchestrator
*not* be in the loop on most coordination. If every parallel
subagent had to ask "what defect ID do I get?", S3 would
saturate. S2's whole purpose is to absorb that variety at the
convention layer.

### The invariant (runtime-neutral)

- **One concurrent editor, one isolated workspace, one disjoint
  write scope.** If the runtime cannot provide that invariant,
  serialise.
- **Subagents do not manage worktrees.** The orchestrator decides
  isolation before dispatch. Briefs describe relative paths and write
  scope, not `git worktree`, `cd`, or cleanup commands.
- **Merge back deterministically.** When each editor returns,
  merge or cherry-pick its commits back in a defined order.
  Resolve conflicts at merge time, not at edit time.
- **Read-only subagents share the main checkout.** Reviewers,
  planners, and exploration subagents do not need isolation.
- **Serial when the work doesn't partition.** Sub-tasks that
  touch the same file or build on each other's output run
  serially.

### Runtime adapters

- **Claude-style runtimes:** if the Agent/Task tool supports
  native worktree isolation, request it for each concurrent
  editor; use the runtime-reported branch/path for deterministic
  merge-back.
- **Codex-style runtimes:** spawn editing agents as `worker`
  agents in forked workspaces with disjoint write scopes. If a
  Codex runner writes workers into the same checkout, create one
  `git worktree` per concurrent editor before dispatch, pass it
  as the editor's working directory if the runner supports it,
  and remove the worktree after merge-back; if it cannot target
  a worktree, serialise. Do not use a Claude-only `isolation`
  parameter in Codex briefs.
- **Other runtimes:** use the runtime's native per-agent checkout
  isolation when it exists. Otherwise create explicit `git
  worktree` checkouts and merge in a defined order.

### vsm-loop-specific S2 rules

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

- **S4 (planning, research) subagents** — frontier reasoning model
  with the largest context. Codex equivalent: strongest available
  GPT-5.x reasoning model with high or extra-high reasoning effort.
  The plan must hold the goal, the ledger, and cross-cutting decisions
  simultaneously.
- **S3\* (audit, review) subagents** — same. Codex equivalent:
  strongest available reviewer/explorer on the frontier reasoning
  model. Adversarial review is exactly where a weaker model regresses
  to surface checks.
- **S1 (execution, fix) subagents** — strong coding model default.
  Codex equivalent: `worker` agents; medium reasoning for mechanical
  edits, high reasoning when the task involves design judgement. Most
  S1 work is mechanical once the brief is good. Escalate to a stronger
  model for S1 tasks that are design decisions in disguise.
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

Default paths use the repo root. If the root is already crowded
or convention prefers nested state, override to `./docs/state/`
(e.g. `./docs/state/tasks.md`, `./docs/state/defects.md`).
Whichever you pick, use it consistently — the ledger schema and
discipline are unchanged.

- `./tasks.md` — active task ledger (S3's working set).
  Checked in.
- `./defects.md` — active defect ledger. Checked in.
- `./docs/archive/tasks-<milestone-id>.md` — completed tasks for a
  closed milestone. Checked in.
- `./docs/archive/defects-<milestone-id>.md` — resolved defects for a
  closed milestone. Checked in.
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
