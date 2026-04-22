# Constructive Test Taxonomy

A multi-axis framework for classifying tests. Each test gets one tag per axis.
The traditional vocabulary (Unit / Functional / Integration) is imprecise — a
single test typically fits several of those categories at once, which makes it
impossible to say which tests are *better* and why. This taxonomy replaces that
vocabulary with three orthogonal axes, each with explicit weights that estimate
maintenance cost.

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

### 1. Intention — *why* the test exists

| Tag          | Weight | Meaning                                                      |
|--------------|--------|--------------------------------------------------------------|
| Contractual  | 1      | Verifies a specified behavioral contract of the code.        |
| Regression   | 2      | Pins a previously discovered bug so it cannot return.        |
| Progression  | 3      | Documents a *known* issue that cannot yet be fixed.          |
| Benchmark    | 4      | Measures performance / resource use.                         |

**Contractual > Regression > Progression > Benchmark.** Prefer contractual
tests: they describe what the code *is*, not accidents of its history. Every
regression test is a hint that a missing contractual test let a bug through.

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

Every test is a point in Intention × Encapsulation × Isolation space —
3 × 3 × 4 = 36 cells. Label tests with a short abbreviation:

- **CBA** = Contractual-Blackbox-Atomic
- **CBG** = Contractual-Blackbox-Group
- **REG-WA** = Regression-Whitebox-Atomic
- **BENCH-E-Evil** = Benchmark-Effectual-EvilCommunication

## Maintenance Cost Heuristic

```
MaintenanceTime ≈ (Intention × Encapsulation × Isolation) / √coverage
```

This is a rough estimator, not a formula to compute with. Its purpose is to
make the ranking explicit:

- A CBA test costs ~1 unit. A Contractual-Whitebox-EvilCommunication test
  costs ~100,000 units. These are not in the same league.
- Adding coverage dilutes cost sub-linearly — lots of cheap tests beat a few
  expensive ones.

## Decision Rules

1. **Prefer low-weight cells.** Target **CBA** and **CBG** for the bulk of the
   suite.
2. **Push tests toward Blackbox.** If a test needs whitebox access, ask
   whether the thing it inspects should be promoted to the public interface
   (or whether it should not be tested directly at all).
3. **Move Good/Evil-Communication tests behind interfaces.** See the
   `dual-tests` skill — dual tests let you express business-logic tests as
   Blackbox-Atomic/Group while still retaining a small, slow set of
   communication tests.
4. **Every Regression test is a gap report.** When you add one, ask what
   Contractual test was missing that let the bug through.
5. **Progression tests are temporary.** They track known issues; they become
   Contractual tests when the issue is fixed.
6. **Benchmarks are not correctness tests.** Don't gate correctness CI on them.
7. **Evil-Communication is quarantined.** Never in pre-merge CI; run on a
   schedule or on demand, with explicit awareness that failures may not mean
   your code is wrong.

## Applying the Taxonomy in Practice

When you are about to write or review a test, tag it:

- *Intention?* Why does this test exist?
- *Encapsulation?* What does it look at?
- *Isolation?* What does it touch?

If the label has any high-weight component, stop and ask: *can this be moved
toward the origin?* Usually yes, via better interfaces, fakes/dummies, or by
splitting the test into a cheap behavior test plus a rare integration test.

## "Zero Element" — the Limit of Testing

Some tests have no meaningful version — e.g., an "Atomic-Blackbox-Contractual
test that a function cannot accept a negative number" when the type system
already forbids negatives. The missing test corresponds to a contract expressed
*in the type system itself*. That is the ideal: push contracts into types so
tests become unnecessary. An unreachable test is a design success, not a gap.

## Summary

- Replace Unit/Integration/E2E with three orthogonal tags.
- Prefer **Contractual-Blackbox-Atomic/Group** tests.
- Whitebox and Evil-Communication are expensive; use sparingly and
  deliberately.
- Every test's label is a design signal: a high-weight label usually means
  the code under test needs a better interface.
- See `dual-tests` for the concrete pattern that produces cheap Blackbox tests
  around code that touches external systems.
