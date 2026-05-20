# Research Loop: Investigate → Hypothesise → Evidence → Validate → Iterate

A disciplined workflow for complex investigation and research tasks.
Subagents gather evidence; the orchestrator validates evidence against
source and adjudicates hypotheses. Hypotheses form a tree that is
traversed depth-first. Use this when the task requires reasoning over
multiple competing explanations across several code paths — i.e. when a
single linear read of the code would miss a hypothesis, or when the
answer hinges on cross-cutting evidence.

## Non-negotiable rules

- **Never gather evidence yourself.** Every hypothesis is investigated
  by a subagent with a self-contained brief. Your job is orchestration:
  forming hypotheses, briefing subagents, validating their evidence,
  adjudicating verdicts, and deciding where to go next.
- **Validate every piece of evidence.** A subagent's `Sender.cs:347` is
  a *claim*. Open the file, read the cited lines, mark the evidence
  item as `correct`, `incorrect`, or `unverified`. Hypothesis verdicts
  may only be drawn from `correct` evidence. Incorrect evidence is left
  in the ledger as a refuted citation and the subagent is briefed again
  if it matters.
- **Hypotheses form a tree.** Refinements discovered while testing
  become child nodes (`H1.1`, `H1.1.2`, `H1.1.2.2`). The numbering
  reflects ancestry. Both subagents and the orchestrator can extend
  the tree: subagents *propose* children with their own evidence
  during testing; the orchestrator may *add* children directly when
  validation, cross-cutting evidence, or a sharper framing makes a new
  refinement obviously worth its own node. The orchestrator decides
  what enters the ledger either way.
- **Traverse depth-first.** Pick a branch, drill it to its leaves
  (confirmed/wrong), then DFS-pop to the next branch. Don't fan out
  breadth-first across unrelated branches once a branch is open —
  evidence collected drilling one branch often closes neighbours
  without a separate subagent.
- **Run independent subagents in parallel only when seeding.** When
  seeding round 1 with several disjoint top-level hypotheses, dispatch
  parallel read-only subagents in the runtime's parallel-call form.
  Codex equivalent: use `explorer` or default read-only agents in
  parallel. Once drilling a branch, go serial — each round's findings
  reshape the next round's questions.
- **The ledger is durable.** It persists between iterations and across
  sessions. Append findings; never rewrite history. A wrong hypothesis
  stays as `wrong` with its evidence — it is not deleted. Incorrect
  evidence stays as `incorrect` so a future round doesn't re-cite it.
- **At least one hypothesis must end `confirmed`.** A loop that closes
  with every hypothesis `wrong` or `uncertain` is not done — expand the
  hypothesis set and iterate. For negative-result investigations,
  model the negative result as a bounded null/completeness hypothesis
  and confirm that hypothesis with evidence.

## The ledger

Path: `./docs/research/research-<short-kebab-description>.md`. Create
the directory if it does not exist. One file per research task; reuse
the same file across iterations of the same investigation.

**Status legends** (always include verbatim near the top):

```
Hypothesis state: `confirmed` · `uncertain` · `wrong`
Evidence state:   `correct` · `incorrect` · `unverified`
```

**Skeleton:**

```markdown
# <Research Title>

<One-paragraph description of what is being investigated and why.
Quote the user's original question verbatim if useful.>

Hypothesis state: `confirmed` · `uncertain` · `wrong`
Evidence state:   `correct` · `incorrect` · `unverified`

---

## H1 — <Headline that states the hypothesis as a claim>

<Prose describing the hypothesis: what is being claimed, what would have
to be true in the code/data for it to hold, and what evidence would
confirm or refute it.>

**State:** `confirmed` | `uncertain` | `wrong` — <one-line rationale,
naming the evidence items it rests on (e.g. "rests on E1.✓, E3.✓; E2
incorrect and discarded").>

**Children:** [[H1.1]] [[H1.2]]   (omit line if no children)

**Evidence:**
- **E1** [`correct`] — `Sender.cs:341-370`: `while (!token.IsCancellationRequested) { try { Delete(...); return; } catch (Locked) { Yield(); } }` — loop exits without deleting on cancellation. Source-verified round 1.
- **E2** [`incorrect`] — subagent claimed `Sender.cs:30 sleep(5000)` exists; line 30 is actually `private bool StartEventsSenderCondition() { ... }`. Citation refuted round 1; subagent re-briefed.
- **E3** [`unverified`] — subagent claimed `Peek` query has no WHERE filter; quoting `EventsQueueRepo.cs:58`. Pending validation round 2.

**Research log:**
- **Round 1** — subagent X. Returned E1, E2, E3. Proposed child H1.1 (cooperative cancel) and H1.2 (OS kill) with evidence E1.1.a, E1.2.a.
- **Round 2** — orchestrator validated E3 against source → `correct`. Adjudicated state: `confirmed` on the strength of E1, E3.

---

## H1.1 — <Sub-headline>

Parent: [[H1]]

<Description specific to this refinement.>

**State:** ...

**Evidence:**
- **E1.1.a** [`correct`] — <citation>
- ...

**Research log:** ...
```

Rules:

- **Headlines state the claim, not the question.** "BundleQuery
  excludes Deleted bundles" — not "does BundleQuery exclude Deleted
  bundles?" The headline must read as a falsifiable proposition.
- **Hypothesis IDs encode ancestry.** `H1.1.2` is the second refinement
  of the first refinement of `H1`. Don't renumber when a sibling
  closes; gaps are fine.
- **Evidence IDs are scoped to their hypothesis.** `E1`, `E2`, ...
  under `H1`; `E1.1.a`, `E1.1.b`, ... under `H1.1` (letters keep them
  short while still globally unique with the parent ID). Use any
  monotonic scheme as long as the prefix matches the hypothesis ID.
- **Never delete a hypothesis or evidence item.** Flip state and
  record why. Past `incorrect` evidence is the cheapest way to prevent
  the same wrong citation in a future round.
- **Cite file:line for every finding.** Include enough surrounding
  context in the evidence body that the orchestrator can verify the
  citation without rereading the whole file (a 3-5 line excerpt is
  usually enough). Vague claims ("the cache layer seems off") force
  the next round to redo the lookup. Reject subagent reports that
  don't include excerpts.
- **Round numbers correspond to orchestrator iterations**, not
  subagent invocations. Two parallel subagents in round 3 both write
  under `Round 3` (one bullet each, naming the hypothesis they
  tested).
- **Never assume.** Form and check facts, verify code paths before
  reporting. Trigger follow-up investigation if a hypothesis rests on
  unconfirmed facts.

### Null / completeness hypotheses

When the user's question can legitimately answer "no matching case
exists" or "none of the proposed causes apply", create an explicit
null/completeness hypothesis. Do not rely on all other hypotheses
ending `wrong`; that only says the tried explanations failed.

The null/completeness hypothesis must define:

1. **Scope** — exact repository paths, runtime components, data set,
   time window, or API surface being searched.
2. **Predicate** — the concrete condition that would count as a match.
3. **Search operations** — commands, code paths, indexes, tests, or
   source reads used to cover the scope.
4. **Completeness limit** — what remains outside the scope, if
   anything.

Example:

```markdown
## H0 — No caller under `src/server/` invokes `send()` without a timeout

**State:** `confirmed` — rests on E0.a, E0.b. The claim is bounded to
static call sites under `src/server/`; dynamic calls via reflection are
outside scope.

**Evidence:**
- **E0.a** [`correct`] — `rg "send\\(" src/server` returned 12 call
  sites; each passes a non-null timeout argument. Source-verified round 1.
- **E0.b** [`correct`] — `SenderFactory.cs:44-71` constructs all
  server-side senders and does not expose a timeout-free wrapper.
```

## The loop

1. **Investigate** — read the user's request, the relevant code, and
   any prior ledger for this topic. Form a set of top-level
   hypotheses (`H1`, `H2`, ...) that, between them, plausibly cover
   the answer space. Aim for breadth at the root: two is rarely
   enough; five to ten is normal.
2. **Seed the ledger** — write each top-level hypothesis as a `## Hn`
   entry with the headline, prose description, empty `Evidence:`
   block, and `State: uncertain`. Create
   `./docs/research/research-<name>.md` if it does not exist.
3. **Pick the next branch (DFS)** — choose the leftmost open
   hypothesis whose state is `uncertain`. Within a branch, prefer the
   deepest open node (most-specific refinement first). Open
   neighbours wait until the current branch closes.
4. **Brief one subagent** for the chosen hypothesis. The brief is
   self-contained: hypothesis ID, headline, prose, exact files/paths
   to inspect, the form of evidence that would confirm or refute the
   claim, and a request to return:
   - Numbered evidence items, each with a file:line citation, a 3-5
     line excerpt, and a one-line "why this matters" for the
     hypothesis.
   - Optionally, proposed child hypotheses (`H<parent>.<n>` with
     headline + prose + its own evidence items) if the trace reveals
     a sharper or distinct variant the parent doesn't capture.
   - A one-line summary of what the subagent believes the verdict
     should be — for orchestrator use only; final adjudication is
     yours.

   When **seeding round 1** with several disjoint top-level
   hypotheses, brief multiple subagents in parallel (one message,
   multiple subagent calls). After round 1, drilling a branch is
   usually serial — each round informs the next.
5. **Validate evidence** — for every evidence item the subagent
   returned, open the cited file at the cited line, confirm the
   excerpt matches, and mark the item `correct` or `incorrect`. Add
   `unverified` only if a citation can't be reached this round (e.g.
   external system) and the investigation can still proceed. Do not
   skip this step. A confidently-cited but wrong line is the dominant
   way a research loop confirms the wrong hypothesis.
6. **Evaluate and extend the hypothesis tree** — two sources of new
   nodes:
   - **Subagent-proposed children**: for each proposed
     `H<parent>.<n>`, **adopt** if it's a sharper variant of the
     parent that the parent's wording doesn't cover and that has at
     least one plausible evidence item — add it with
     `State: uncertain`. **Discard** if it's restating the parent or
     speculative without evidence; note the rejection in the parent's
     research log so it isn't re-proposed.
   - **Orchestrator-added children**: while validating evidence or
     reading the cited files, you will often see a sharper question
     the subagent didn't ask. Add it as `H<parent>.<n>` directly.
     Cite the evidence item (yours or the subagent's) that motivated
     it in the new node's research log so the provenance is visible.
     Don't let "the subagent didn't raise it" be the reason a
     load-bearing refinement goes unrecorded.
7. **Adjudicate the hypothesis verdict** — set `State` to
   `confirmed`, `wrong`, or `uncertain`, drawing *only* on `correct`
   evidence. A hypothesis is `confirmed` when the correct evidence
   directly supports the claim; `wrong` when correct evidence refutes
   it; `uncertain` otherwise. Absence of counter-evidence is not
   confirmation. Update the rationale to name the evidence items it
   rests on.
8. **Append to research log** — one bullet under `Round <n>` for the
   subagent's contribution, one bullet for your validation pass. This
   is orchestrator work, not subagent work.
9. **Decide where to go next** —
   - If this hypothesis is now `confirmed` or `wrong` and has no live
     children → DFS-pop, return to step 3 to pick the next branch.
   - If this hypothesis spawned adopted children → step 3 with the
     new deepest open node on the current branch.
   - If this hypothesis is still `uncertain` (e.g. evidence was
     incorrect, or new questions opened) → step 4, re-brief with the
     refined question.
10. **Stop when** the user's question is answered: every leaf
    hypothesis is `confirmed` or `wrong` (none `uncertain`) and at
    least one root or descendant is `confirmed`. The confirmed node may
    be a bounded null/completeness hypothesis. See **Stop conditions**
    below.
11. **Deliver** — write the research result to the user: which
    hypothesis (or hypotheses) was confirmed, the key validated
    evidence with file:line citations, a brief note of which
    branches were ruled out, and a pointer to the ledger. Keep it
    short; the ledger is the long form.

## Stop conditions

Only two valid terminations:

- **Answered.** At least one hypothesis is `confirmed` and no
  hypothesis (root or descendant) remains `uncertain`. The user's
  question has a direct answer backed by validated evidence. Deliver
  the result. If the answer is negative, the confirmed hypothesis must
  be an explicit null/completeness hypothesis with a stated scope and
  completeness limit.
- **Blocked on user input.** The investigation has uncovered a
  question that cannot be resolved from the code or the original
  brief: ambiguous scope, missing system access, or a choice the
  user must make about which sub-question matters. Record the
  blocker as a final `## Blocker` section in the ledger and ask the
  user.

Running out of patience, hitting a "probably this" hunch without
evidence, wanting to check in mid-investigation, or observing that
"nothing matched" without a bounded null/completeness hypothesis are
**not** stop conditions. Iterate.

## Subagent briefing discipline

Each subagent starts cold. A brief that works:

- States the **one hypothesis** this subagent is testing (full ID,
  headline, and prose).
- If drilling a child, includes the parent's verdict and the
  evidence that motivated the refinement.
- Points at **exact file paths** (and line ranges where known) to
  inspect, plus any test files, logs, or external docs relevant to
  the claim.
- Names the **form of evidence** that would confirm vs refute the
  hypothesis ("show that function X is called before Y in path Z" /
  "show that no caller of A passes B = null").
- Requires findings as a **numbered list of evidence items**, each
  with a file:line citation, a 3-5 line excerpt the orchestrator
  can verify against, and a one-line "why this matters" for the
  hypothesis. Reject vague conclusions.
- Permits the subagent to **propose child hypotheses**
  (`H<parent>.<n>`) if the trace reveals a sharper variant — but
  each proposed child must come with its own evidence items in the
  same format.
- Says the subagent is **read-only** — it investigates, it does not
  edit code.
- Closes with a one-line ask for the subagent's *proposed* verdict
  on the hypothesis. (Final adjudication is the orchestrator's, but
  the subagent's read often surfaces a useful framing.)

A brief that fails: "look into hypothesis H3" or "research the
caching layer." Those push synthesis onto the subagent. You have the
context; transfer it.

## Parallelism

- **Seeding (round 1)**: top-level hypotheses that touch disjoint
  code paths → parallel subagents in a single message.
- **Drilling a branch**: usually serial. Each round's findings (new
  evidence, new child hypotheses, refuted citations) reshape the
  next round's question. Parallel drilling on the same branch
  duplicates work and often misses the cross-cutting evidence one
  subagent's trace would have surfaced for another.
- **Adopting children proposed mid-round**: drill them serially as
  part of the current branch's DFS, not in parallel with their
  parent's siblings.
- Reviewing, evidence validation, and adjudication are orchestrator
  work, not subagent work.
- All research subagents are **read-only**, so they may share the main
  checkout. No worktree isolation is required for pure evidence
  gathering.

## Model selection per phase

Research quality is dominated by the quality of **hypothesis
formation**, **evidence validation**, and **review** — those are
where weaker reasoning silently misses the actual cause, accepts a
mis-cited file:line, or treats absence of evidence as confirmation.
The hypothesis-testing subagents themselves are usually mechanical
once the brief names the files and the evidence form.

Default model assignment, overridable when a task obviously warrants
it. Names are role classes; map them to the strongest stable model
available in the current runtime:

- **Orchestrator (hypothesis formation, evidence validation,
  adjudication — i.e. you):** frontier reasoning model with the
  largest available context. Codex equivalent: strongest available
  GPT-5.x reasoning model with high or extra-high reasoning effort.
  The orchestrator holds the full code context and the ledger
  simultaneously; this is exactly where a weaker model regresses to
  surface-level pattern matching or accepts unverified citations.
- **Research subagents:** strong code-reading model by default. Codex
  equivalent: `explorer` or default read-only agents; use higher
  reasoning for hypotheses that require design judgement. Most
  evidence-gathering reduces to "read these files, report what you
  find with excerpts." Escalate to a stronger model when the
  hypothesis requires non-trivial design reasoning to evaluate (e.g.
  "is this race condition reachable from any caller").
- **Ledger maintenance, results delivery:** orchestrator (you), no
  subagent.

Never downgrade the orchestrator to save cost — missed hypotheses
and unvalidated evidence compound across rounds, and a confidently
delivered wrong answer is the dominant failure mode of this loop.

## What lives where

- `./docs/research/research-<name>.md` — the persistent research
  ledger for this investigation. Survives across sessions. The tree
  of hypotheses, all evidence items with their validation status,
  and the round-by-round log all live here.
- Code — read-only during the research loop. If the investigation
  reveals a change that should be made, deliver that as a follow-up
  recommendation, not as part of the research loop itself.
- Nothing transient (intermediate subagent transcripts, draft
  hypotheses you discarded before recording, evidence the subagent
  proposed but you rejected on validation) needs to survive — the
  ledger and the final result are the record. Rejected proposals
  should still be noted as one line in the research log so the same
  proposal isn't reconsidered next round.
