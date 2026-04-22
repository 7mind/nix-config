# Constructive Test Taxonomy

A multi-axis framework for classifying tests. Each test gets one tag per axis.
The traditional vocabulary (Unit / Functional / Integration) is imprecise — a
single test typically fits several of those categories at once, which makes it
impossible to say which tests are *better* and why. This taxonomy replaces that
vocabulary with three orthogonal axes — **Intent**, **Encapsulation**,
**Isolation** — each with explicit weights that estimate maintenance cost.
Intent splits into three sub-axes (Purpose, Status, Origin); Origin is
provenance metadata rather than a classification tag.

## Problem with Unit / Integration / E2E

- A "unit test" that mocks a database is simultaneously unit-level (one class)
  and integration-level (needs DB-like behavior).
- "Integration test" conflates "talks to a real DB" with "talks to a real
  third-party API" — two categories with radically different reliability.
- Changing implementation (e.g., swapping a real DB for an in-memory fake)
  changes the test's traditional category without changing what it verifies.

The traditional labels describe *accidents of implementation*, not *what the
test is for*. The axes below describe the latter.

## The Three Axes

### 1. Intent — three sub-axes

A test's "intent" is not a single property. It answers three independent
questions. Two of the sub-axes are classifications (carry weight, label the
test); the third is **provenance** and belongs in metadata, not in the label.

#### 1a. Purpose — *what does this test measure?*

| Tag         | Weight | Meaning                                                  |
|-------------|--------|----------------------------------------------------------|
| Behavioral  | 1      | Asserts correctness of observable behavior.              |
| Performance | —      | Measures resource use (latency, throughput, memory).     |

Performance tests (benchmarks) are evaluated on different criteria (stability
of measurement, whether they gate merges) and do not sit on the
correctness-cost hierarchy. They have no weight here — treat them as a
separate suite.

#### 1b. Status — *how does this test participate in CI right now?*

| Tag         | Weight | Meaning                                                  |
|-------------|--------|----------------------------------------------------------|
| Active      | 1      | Expected to pass. Gates CI.                              |
| Progression | 3      | Expected to fail. Documents a known unresolved issue.    |

Progression tests are temporary by nature: they become Active tests when the
underlying issue is fixed, or they are deleted when the issue is abandoned.
Their higher weight reflects the debt they carry in the suite.

#### 1c. Origin — *why was this test added?* (metadata, not a classification)

| Tag        | Meaning                                                          |
|------------|------------------------------------------------------------------|
| Specified  | Written from a contract or requirement, a priori.                |
| Regression | Written in response to a discovered defect.                      |

**Origin is provenance, not a classification axis.** It records history, not
structure — two tests with identical behavior can have different Origins
purely based on when and why they were added. Do **not** put Origin into the
test's label. Record it as metadata:

- a comment near the test (`// regression: bug #1234 — duplicate email silently accepted`),
- an annotation/tag on the test (`@regression(issue=1234)`),
- or the commit message that introduced the test.

Origin does not appear in the maintenance-cost heuristic. It matters for two
things only: **auditing** (where did this test come from, is the linked bug
still relevant?) and the insight that **every Regression-origin test signals
a gap in the Specified-origin tests** — a missing contract that let a bug
slip through.

### 2. Encapsulation — *how much implementation knowledge* the test needs

| Tag       | Weight | Meaning                                                         |
|-----------|--------|-----------------------------------------------------------------|
| Blackbox  | 1      | Exercises only the public interface. Survives refactoring.      |
| Effectual | 10     | Uses the public interface but asserts on external side effects (files, network, DB rows). |
| Whitebox  | 100    | Inspects internal state or private implementation details.      |

**Lower is dramatically cheaper.** Whitebox tests are refactoring-hostile:
every internal restructuring breaks them even when behavior is unchanged. The
weights reflect the relative cost of keeping each kind alive over time.

### 3. Isolation — *scope and external dependencies*

| Tag                | Weight | Meaning                                                      |
|--------------------|--------|--------------------------------------------------------------|
| Atomic             | 1      | Exercises a single component in isolation.                   |
| Group              | 5      | Exercises several internal components together (in-process). |
| Good Communication | 100    | Talks to a controllable external system (local DB, container). |
| Evil Communication | 1000   | Depends on an uncontrollable external system (third-party API, public internet). |

**Good vs. Evil communication is the critical distinction.** A local
Postgres in a container is fundamentally different from a test that hits a
live third-party API: the former fails only when *your* code is wrong; the
latter fails when the world is wrong. Evil-communication tests belong in a
separate tier you run rarely and never in pre-merge CI.

## Test Space and Labels

Every test is a point in Purpose × Status × Encapsulation × Isolation space
(Origin is metadata and does not enter the label). The default intent is
**Behavioral + Active** (the overwhelming majority of tests), so labels
typically spell out only Encapsulation × Isolation and omit the default
intent. Non-default intents are spelled out explicitly.

- **BA** = (Behavioral-Active-)Blackbox-Atomic
- **BG** = (Behavioral-Active-)Blackbox-Group
- **WA** = (Behavioral-Active-)Whitebox-Atomic
- **Progression-BA** = Progression-status Blackbox-Atomic
- **Perf-E-Good** = Performance-purpose Effectual Good-Communication

Origin, when relevant, is attached as metadata alongside the label:
`BA @regression(issue=1234)`.

**Most cells are rarely used.** In practice tests cluster in a handful of
cells, and the rest are either empty or signal a smell:

- **Load-bearing cells**: BA, BG — where the bulk of the suite should
  live. Effectual-GoodCommunication and a small *-EvilCommunication tier
  for genuine integration coverage.
- **Smell cells**: any cell with Whitebox is a hint the interface is wrong.
  Any cell with EvilCommunication outside a quarantined tier is a hint the
  suite is fragile.
- **Near-empty cells**: Performance-Whitebox-*, Progression-Effectual-*,
  etc. usually don't represent real tests people write.

The grid is a map of possibilities, not an expectation that every cell will
be populated. If you find yourself labeling tests across most of the grid,
the suite is likely sprawling rather than comprehensive.

## Maintenance Cost Heuristic

```
MaintenanceTime ≈ (Purpose × Status × Encapsulation × Isolation) / √coverage
```

**The weights are intuition, not measurement.** They are calibrated by
experience to encode a rough ordering; they are not inputs to arithmetic.
Do not use them to answer "is this suite under budget?" or "is test A
literally 100× more expensive than test B." Use them only to make the
*ordering* explicit:

- A BA (Behavioral-Active-Blackbox-Atomic) test is cheap; a
  Whitebox-EvilCommunication test is ruinous over a project's lifetime.
  They are not in the same league, and that is the only claim the formula
  actually makes.
- Adding coverage dilutes cost sub-linearly — lots of cheap tests beat a few
  expensive ones.
- **Origin is not a factor**: it's metadata about how a test came to exist,
  not a driver of its maintenance cost. Two identical tests cost the same
  to maintain regardless of whether one was written a priori and the other
  after a bug.

Treat the formula as a mnemonic for the hierarchy, not a model of reality.

## Decision Rules

1. **Prefer low-weight cells.** Target **BA** and **BG** (Behavioral-Active
   × Blackbox × Atomic/Group) for the bulk of the suite.
2. **Push tests toward Blackbox.** If a test needs whitebox access, ask
   whether the thing it inspects should be promoted to the public interface
   (or whether it should not be tested directly at all).
3. **Move Good/Evil-Communication tests behind interfaces.** See the
   `dual-tests` skill — dual tests let you express business-logic tests as
   Blackbox-Atomic/Group while still retaining a small, slow set of
   communication tests.
4. **Every Regression-origin test is a gap report.** When you add one, ask
   what Specified-origin test was missing that let the bug through. Record
   Origin as metadata, not in the label.
5. **Progression is temporary.** Progression-status tests track known
   issues; they transition to Active when the issue is fixed, or are
   deleted.
6. **Performance tests are a separate suite.** Don't gate correctness CI on
   them; they live outside the correctness-cost hierarchy.
7. **Evil-Communication is quarantined.** Never in pre-merge CI; run on a
   schedule or on demand, with explicit awareness that failures may not mean
   your code is wrong.

## Applying the Taxonomy in Practice

When you are about to write or review a test, tag it:

- *Purpose?* Behavioral or Performance?
- *Status?* Active or Progression?
- *Encapsulation?* What does it look at?
- *Isolation?* What does it touch?
- *Origin?* (metadata only) Specified or Regression — record in a comment
  or annotation, not in the label.

If the label has any high-weight component, stop and ask: *can this be moved
toward the origin of the coordinate space?* Usually yes, via better
interfaces, fakes/dummies, or by splitting the test into a cheap behavior
test plus a rare integration test.

## "Zero Element" — the Limit of Testing

Some tests have no meaningful version — e.g., a "Blackbox-Atomic test that
a function cannot accept a negative number" when the type system already
forbids negatives. The missing test corresponds to a contract expressed *in
the type system itself*. That is the ideal: push contracts into types so
tests become unnecessary. An unreachable test is a design success, not a gap.

## Summary

- Replace Unit/Integration/E2E with three orthogonal axes (Intent,
  Encapsulation, Isolation); Intent splits into Purpose, Status, and Origin.
- Origin is **provenance metadata**, not a classification — keep it in
  comments or annotations, not in the label.
- Prefer **Behavioral-Active × Blackbox × Atomic/Group** tests (shortened
  to BA / BG).
- Whitebox and Evil-Communication are expensive; use sparingly and
  deliberately.
- Every test's label is a design signal: a high-weight label usually means
  the code under test needs a better interface.
- See `dual-tests` for the concrete pattern that produces cheap Blackbox tests
  around code that touches external systems.
