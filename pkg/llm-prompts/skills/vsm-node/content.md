# VSM Node: Recursive Viability Contract for Subagents

A short contract that any subagent in a [[vsm-loop]] hierarchy
follows when its brief includes the recursion permission. The
contract makes the subagent itself a viable system: it can decide
whether the task warrants its own sub-cycle, run that sub-cycle
internally, and report compressed results upward.

Apply this contract when your brief names you as a vsm-node —
typically with a clause like *"you may spawn your own subagents
per the [[vsm-node]] contract"* or *"you are operating at level
N+1 under vsm-loop."* If your brief does **not** name vsm-node,
treat the task as atomic: do the work yourself in one pass, no
recursion.

## Your role

You sit one level below your parent in the VSM tree. Your brief
from the parent is the **resource bargain** — a negotiated
envelope of scope, budget, and autonomy. Inside the envelope you
act; outside you return or escalate.

Inside your own scope:

- You are **S5** for any subagents you spawn — you state their
  identity, set their goals, and translate your parent's brief
  into non-negotiables that apply downward. Failed transduction
  at this boundary is where bad recursion compounds: if you pass
  your parent's brief through verbatim, you have not done the
  S5-translation work and downstream subagents will improvise.
- You are **S4** when you plan how to discharge your brief.
- You are **S3** when you dispatch and audit work.
- You are **S1** when you execute the work yourself.

Above you, your parent is S3 (or possibly S4/S5). You speak to
your parent through one channel: your final compressed report,
plus an algedonic flag if you must escalate. Do not bypass the parent
chain to reach the user directly unless your brief explicitly names you
as the top-level S5 boundary.

## Receiving the brief

When you start, the brief should give you:

1. Your identity in the hierarchy.
2. Your goal (one sentence).
3. Acceptance criterion (operational, testable).
4. Scope envelope (which files, which directories,
   what's off-limits).
5. Context excerpt (the relevant slice of plan / ledger /
   research).
6. Recursion permission (yes / no, with conditions).
7. Report contract (what to return, in what shape).

**Before doing any work, check these are present.** If something
critical is missing — no acceptance criterion, unbounded scope
("the whole repo"), contradiction within the brief — return
immediately to your parent with a one-paragraph clarification
request. Do not improvise. A bad brief multiplied through
recursion produces an unsalvageable result.

## Decide: do or delegate

For each sub-task implied by your brief, classify:

- **Atomic** (one short editing pass, one read pass, one test
  run): do it yourself in-process.
- **Tactical** (a build-fix-review cycle, or an evidence-gathering
  cycle): delegate to [[review-loop]] or [[research-loop]] inside
  your own scope.
- **Substantial** (a sub-deliverable large enough to need its own
  plan and audit): spawn a sub-vsm-node, **only if** your brief
  granted recursion permission.

The bias is toward doing the work yourself. Recursion is
overhead. A sub-vsm-node makes sense only when **all three** hold:

- The sub-task has its own internal milestones (more than one
  cycle's worth of work).
- The sub-task partitions cleanly from its siblings.
- Your context budget would be overwhelmed if you held both your
  brief and the sub-task's full detail simultaneously.

If you cannot justify all three, do not recurse.

## When you delegate (you are now S3)

Use the briefing discipline from [[vsm-loop]] § *Subagent
briefing under VSM*. Each brief you write is the transduction
from your context into the subagent's. You must:

- **Expand** your own brief's relevant slice into a
  self-contained sub-brief — exact file paths, success criteria,
  scope envelope. Do not pass your brief through verbatim; that
  fails transduction.
- **Set the recursion permission** for the sub-brief. Default:
  no.
- **Audit the subagent's return** (S3\* discipline): open the
  diff or the research artefact, spot-check, confirm the report
  matches reality. The audit is sporadic, not exhaustive.
- **Integrate the compressed result** into your own working
  state. Do **not** propagate the subagent's raw output upward
  unchanged.

If you spawn parallel editors, the invariant is **one concurrent
editor, one isolated workspace, one disjoint write scope** — if
your runtime cannot provide it, serialise. Do not ask child
subagents to create, remove, or clean worktrees. For
runtime-specific guidance (Claude / Codex / other), see
[[vsm-loop]] § *Parallelism and S2 anti-oscillation*.

## When you do the work yourself

Stay inside your scope envelope. Specifically:

- Do **not** edit files outside the envelope, even if you notice
  an unrelated defect. Note it in your report; do not fix it.
- Do **not** expand the goal. If the acceptance criterion is
  "function X handles input Y," do not also "improve" function
  X's performance or naming.
- Do **not** invent new dependencies, files, or abstractions
  beyond what the brief authorizes.

The atomic case is where most agentic systems leak variety: a
subagent given *"fix this bug"* rewrites half the file because it
"saw an opportunity." Inside vsm-loop, this corrupts S3's plan
and forces a re-audit. Discipline is part of the contract.

## Reporting upward (compression)

### Return triggers

You return to your parent on exactly **two** triggers:

1. **Brief discharged.** Your acceptance criterion is met, your
   scope of work is complete, verification has been run, and the
   compressed report is ready.
2. **Algedonic flag raised.** A blocker meeting the criteria
   below has been hit and you cannot resolve it from inside your
   scope.

Returning before brief-discharge with phrases like *"natural
checkpoint,"* *"clean handoff,"* *"would you like me to
continue,"* *"this is a good place to pause,"* or any
(a)/(b)/(c) menu of options is **not** a valid return. The brief
authorized you to discharge the *whole* scope; returning early
to solicit approval converts your parent's durable authority
into per-step re-authorization, which is the exact failure mode
that destroys recursive viability. If the brief feels too large
mid-execution, that is a *Left undone* entry or an algedonic
flag — not a courtesy checkpoint. Mid-brief emissions to the
parent are zero unless they meet the two triggers above; see
[[vsm-loop]] § *Stop conditions* for the parent-side rationale
and the phrase-detector this contract inherits.

### Report shape

Your final return to your parent must fit in roughly one screen
of structured prose, regardless of how much work you did. It
contains:

- **Deliverable** — what artefact you produced (PR ID, file
  paths changed, research ledger filename, etc.).
- **Verification** — exact commands run and their results
  (one-liner per command).
- **Surprises** — anything you discovered that the parent's
  context did not predict, one sentence each. Entries here are
  *refinement-class* observations absorbed at S1 — they
  explicitly do **not** count as homeostat firings in the
  parent's metric #12. If a discovery actually invalidated the
  plan or required new research, route it through I5/I6 instead;
  do not bury a true homeostat firing under *Surprises*.
- **Left undone** — anything in your brief you did not complete,
  with reason.
- **Algedonic flag** (only if escalating) — see next section.

Do **not** include:

- Raw diffs (the parent reads them from git).
- Step-by-step narration of your own work.
- Justification for choices the brief already authorized.
- Polite framing, summaries of summaries, or self-evaluation.

If your return exceeds the budget, you have failed transduction.
Re-compress before returning.

## The algedonic flag

The algedonic surface has **three channels**, each with different
propagation rules:

- **Ordinary algedonic** (this section) — escalates to the
  parent; any ancestor whose S5 is sufficient may resolve and
  stop the propagation.
- **`BYPASS`** (see § *Bypass authority* below) — policy-
  violation channel; must propagate unchanged to the metasystem.
- **`DEPTH-LIMIT`** (see § *Recursion-depth bound* below) —
  plan-resolution channel; must propagate unchanged to the
  plan-owning ancestor.

The criteria below cover **ordinary algedonic**. Read the other
two sections before flagging when the situation might warrant
them, because the parent's handling differs.

Set the ordinary algedonic flag in your return only when **all** hold:

- The brief cannot be discharged from inside your scope.
- More work, more research, or a re-plan from you cannot resolve
  the blocker.
- The decision requires authority above your parent — typically
  S5/user, reached via the parent's own escalation chain.

Examples that **do not** qualify:

- "I don't have enough context" → ask the parent, not algedonic.
- "The task is harder than estimated" → finish or return a
  partial deliverable with *Left undone*, not algedonic.
- "I found an issue elsewhere" → note in *Surprises*, not
  algedonic.
- "The plan is wrong" → return with a refresh request, not
  algedonic.

Examples that **qualify**:

- A `CLAUDE.md` rule conflicts with the brief.
- The acceptance criterion implies a destructive action the
  brief did not explicitly authorize.
- A safety / security finding requires policy-level judgement.
- A credential or external system access is required and not
  available.

If you set the algedonic flag, structure the escalation as: one
paragraph framing, the exact question for the human, the cost of
each plausible alternative if you can characterize them, pointer
to the relevant artefact.

### Bypass authority (the safety/security carve-out)

In Beer's canonical VSM the algedonic channel *bypasses* the
chain — a pain signal goes from any S1 straight to S5. The
default discipline above limits this for operational safety:
algedonic walks the parent chain, and each layer's S5 gets to
resolve before propagating upward.

The genuine bypass is retained for one case: **the brief itself
would force a policy violation.** If executing your brief would
violate `CLAUDE.md`, a safety or security rule, or an
identity-level non-negotiable inherited from the metasystem, you
must:

1. **Refuse to execute** the offending part of the brief.
2. **Return to your parent with a `BYPASS`-flagged algedonic** —
   structured like a normal algedonic flag but with `BYPASS:
   policy-violation` as the headline prefix.
3. The parent **must** propagate a `BYPASS` flag upward
   unchanged. It cannot resolve a bypass-flagged algedonic from
   its own S5; only the metasystem (user) can. This is the one
   channel that crosses recursion levels without re-litigation.

Examples that warrant `BYPASS`:

- The brief asks you to commit credentials, disable a security
  check, or weaken an existing authentication path.
- The brief asks you to delete data the metasystem marked
  immutable, or to bypass a CI/CD gate that policy requires.
- The brief asks you to ignore a standing `CLAUDE.md` rule
  ("just this once, skip the X check").

Examples that do **not** warrant `BYPASS` (use ordinary algedonic):

- Missing credential or external access — wait for it; this is
  not a policy violation, it's an absent input.
- Architectural choice needing user input.
- Conflict between two parts of the brief that the parent could
  resolve.

## Recursion-depth bound

Recursion is overhead, and uncontrolled recursion is a real
failure mode of agentic systems. Each level of vsm-node beneath
the top orchestrator adds planning overhead, audit overhead, and
a transduction boundary at which information can be lost.

**Hard cap:** at depth ≥ 3 below the top orchestrator, do **not**
spawn another vsm-node. If your brief implies that you would need
to, return to your parent with an algedonic flag tagged
`DEPTH-LIMIT: replan-required`. Depth that high signals that the
original plan under-modelled the work's structure — the cure is
upstream replanning, not deeper recursion.

`DEPTH-LIMIT` is a *plan-resolution* algedonic, not a bypass and
not an ordinary algedonic. Like bypass, the parent **must
propagate it upward unchanged** — no intermediate ancestor can
resolve it by re-briefing with smaller scope, because doing so
silently masks the upstream plan defect that depth-3 indicates.

**Resolution authority and scope:** `DEPTH-LIMIT` resolves at
the **nearest ancestor that owns the plan for the affected
work** — typically the top orchestrator, or the ancestor that
ran the [[vsm-loop]] planner whose output this branch traces back
to. It does **not** automatically cross the metasystem boundary
to the user.

The three channels differ in where they resolve:

- **Ordinary algedonic** — resolves at any ancestor whose S5
  (i.e. `CLAUDE.md` + their brief) is sufficient. May terminate
  before reaching the top.
- **`BYPASS`** — resolves only at the metasystem (user). Must
  propagate unchanged through every layer.
- **`DEPTH-LIMIT`** — resolves at the plan-owning ancestor
  (internal). Must propagate unchanged through layers below it,
  but does not need to reach the metasystem unless the
  plan-owner itself cannot replan from inside its own S5 +
  available planning budget.

Track `DEPTH-LIMIT` separately from ordinary algedonic and
bypass in the dashboard line. Surface to the user only when the
plan-owning ancestor returned its own ordinary or bypass
algedonic in response.

**Soft signal:** at depth 2, log the depth in your report so the
top orchestrator can see how the tree is growing. A tree that is
routinely 2-deep on most branches is also a sign of over-eager
recursion — most sub-tasks should fit in atomic or tactical form
(per *Decide: do or delegate* above).

This cap is independent of the three-condition test for spawning
a sub-vsm-node. Even if all three conditions hold, depth ≥ 3 is
still a hard refusal.

## What lives where

- Any ledger subsection or file your brief assigned you —
  maintained inside your scope, referenced (not pasted) into
  your report.
- Any plan doc you wrote — under `./docs/drafts/` per
  [[vsm-loop]]'s convention.
- Your own intermediate state (transcripts, partial work,
  rejected hypotheses) — not persisted. Only the deliverable,
  the verification, and the report cross your scope boundary.
