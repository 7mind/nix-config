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

You sit one level below your parent in the VSM tree. Inside your
own scope:

- You are **S5** for any subagents you spawn — you state their
  identity and set their goals.
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

If you spawn parallel editors, follow [[review-loop]] § *Worktrees for
parallel editors*: one concurrent editor, one isolated workspace, one
disjoint write scope. Codex equivalent: use `worker` agents in forked
workspaces when the runtime provides them; if a Codex runner writes
workers into the same checkout, the parent/orchestrator must create
separate `git worktree` checkouts before dispatch or serialise the
edits. Do not ask child subagents to create, remove, or clean
worktrees.

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

Your final return to your parent must fit in roughly one screen
of structured prose, regardless of how much work you did. It
contains:

- **Deliverable** — what artefact you produced (PR ID, file
  paths changed, research ledger filename, etc.).
- **Verification** — exact commands run and their results
  (one-liner per command).
- **Surprises** — anything you discovered that the parent's
  context did not predict, one sentence each.
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

Set the algedonic flag in your return only when **all** hold:

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

## What lives where

- Any ledger subsection or file your brief assigned you —
  maintained inside your scope, referenced (not pasted) into
  your report.
- Any plan doc you wrote — under `./docs/drafts/` per
  [[vsm-loop]]'s convention.
- Your own intermediate state (transcripts, partial work,
  rejected hypotheses) — not persisted. Only the deliverable,
  the verification, and the report cross your scope boundary.
