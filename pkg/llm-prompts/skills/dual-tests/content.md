# Dual Tests

A concrete pattern for testing code that touches external systems
(databases, HTTP APIs, message queues, filesystems, clocks). Every test that
depends on an integration point is written against the *interface*, not a
specific implementation, and is executed against **two** implementations:
the production adapter and a hand-written in-memory dummy. This applies
both to the interface's own contract tests and to the business-logic tests
that consume the interface.

The two-run discipline is the heart of the pattern. It gives a fast
feedback signal (dummy) plus a realistic full-verification signal
(production adapter), and — crucially — **forces the dummy to stay honest**:
any behavioral drift between dummy and adapter surfaces as a test
divergence rather than as a silent production bug.

The distinction between the two is **cadence, not venue.** Both runs work
anywhere the environment permits — a developer machine with a local
database, a CI job, a pre-push hook. When a developer is iterating on
business logic, dummy-only runs give the short feedback loop; the full
two-run suite is invoked less often (before pushing, when finishing a
task, or as part of CI).

This is the mechanism that lets most fast-feedback runs sit in the cheap
**BA / BG** region — Behavioral-Active-Blackbox-Atomic/Group (see
`constructive-test-taxonomy`) — while still exercising the production
adapter on the same tests whenever full verification is wanted.

## Problem

Code that touches external systems forces every caller's test to become an
integration test. Typical bad outcomes:

- **Real dependencies in every test**: each test spins up a database,
  produces flakiness, and slows CI.
- **Auto-mocks everywhere**: tests pass by telling a mock framework what to
  expect, then break on any refactor. They verify "these calls happened," not
  "the behavior is correct."
- **Two parallel suites that diverge**: a fast unit suite against mocks, a
  slow integration suite against reality, and silent drift between them.

## The Pattern

1. **Isolate the integration point behind an interface.** The business logic
   depends only on the interface, not on the external system.
2. **Write one abstract test suite against the interface.** The suite
   describes what *any* correct implementation must do, phrased as
   Behavioral-Active-Blackbox tests.
3. **Implement a hand-written in-memory dummy** of the interface using plain
   data structures. Dummies are code you own — small, readable,
   refactor-friendly.
4. **Run the abstract suite against both implementations**: the production
   adapter and the dummy.
   - When the external system is unavailable (no DB running, offline
     developer, environment not provisioned), the production run is
     *skipped* with an explicit marker, not faked. Dummy runs always execute.
5. **Parameterize business-logic tests over the interface too.** A test
   that drives a service using `UserRepository` takes the repository as a
   parameter and runs against both the dummy and the production adapter,
   same as the abstract interface suite. Dummy-backed runs are the fast
   feedback path invoked frequently while iterating; production-backed
   runs validate the actual composition — run them locally when the
   environment is set up, and always at CI time. The two-run regime is
   what keeps the dummy honest: drift shows up as a divergence between
   the runs, not as a production surprise.

The abstract suite is the contract. Both implementations must satisfy it.
If the dummy passes but the production adapter fails, the production adapter
is wrong. If the dummy diverges from production behavior, the abstract suite
is incomplete — *extend the suite*, never paper over the difference.

## Interface Leaks Are Manageable

Real systems leak: a `UserRepository` eventually needs `SELECT ... FOR
UPDATE`, a Postgres-specific upsert, a batched transaction, a vendor-specific
error code. This does not invalidate the pattern — it constrains where you
apply it.

- **Always attempt a narrow interface.** Most leaks come from reaching for
  DB-specific features too early when a cleaner abstraction exists. Push back
  once before accepting the leak.
- **When a leak is genuine, contain it.** Promote the leaky concern to its
  own narrow interface (`class TransactionalUserRepository extends
  UserRepository`) and keep the dummy honest on *that* interface, even if
  crudely. Do not let the leak spread into unrelated interfaces.
- **Accept that some business logic will depend on the leaked concern.**
  Those tests become Good-Communication tests against the real adapter.
  That is fine — they are a small minority, not the bulk of the suite.

The goal is not a leak-free abstraction. The goal is to keep the surface
area of leakage small and explicit so that most business logic still sits
behind a clean interface testable with a dummy.

## Why Dummies Beat Auto-Mocks

Automatic mocks (Mockito, unittest.mock, jest fn, etc.) record call
expectations at runtime. They look cheap because you don't write them. They
are not cheap:

| Concern                | Auto-mocks                             | Hand-written dummies                           |
|------------------------|----------------------------------------|------------------------------------------------|
| Up-front cost          | Near zero                              | Real — you write and maintain an impl          |
| Refactor cost          | High — every signature change breaks every mock site | Low — one dummy implementation, one place to update |
| What they verify       | Call sequences / arguments (whitebox)  | Observable behavior (blackbox)                 |
| Correspondence to prod | None — mocks return whatever you say   | Enforced by the shared abstract test suite     |
| Debuggability          | Failures describe mock configuration mismatch | Failures describe real behavior mismatch |

**Rule: strongly prefer dummies over auto-mocks.** Reach for an auto-mock only
when you are verifying a protocol of *interactions* (retries, call counts,
ordering) where behavior-level equivalence is not enough — and then write it
explicitly, not as a default.

## Implementing a Dummy

A dummy is not a stub that returns canned values. It is a minimal, correct
implementation of the interface backed by plain in-memory data.

- A `UserRepository` dummy → a `Map<UserId, User>` plus the interface
  methods.
- A `Clock` dummy → a settable `Instant` with `now()` returning it.
- A `MessageBus` dummy → an append-only `Vec<Message>` plus a subscriber
  list.
- An `HttpClient` dummy → a routing table from `(method, path)` to a handler
  the test configures.

Dummies are allowed (and expected) to be *strict*: panic on operations the
real system would forbid (e.g., inserting a duplicate primary key). Strictness
is what keeps them behaviorally close to production.

## Rough Equivalence Is Usually Enough

Dummies will drift from production on transaction semantics, error codes,
ordering guarantees, timing, and concurrency — the exact places where real
systems are most interesting. This is a real cost, not a bug you can design
out. Accept it and place it correctly:

- **For business-logic tests, rough equivalence suffices for the fast
  feedback loop.** Most logic only cares that writes are durable, reads
  see prior writes, and constraint violations surface as errors. A dummy
  can provide that cheaply, and iterative work runs exclusively against
  it. The same business-logic tests also run against the production
  adapter — locally when the environment is set up, and at CI — catching
  any place where rough equivalence stops being enough.
- **For behavior that depends on exact semantics** (lock contention,
  isolation levels, retry-on-conflict, partial-batch failures), write
  **targeted Good-Communication tests** against the real adapter. Do not
  try to shoehorn these into the shared abstract suite — they belong in a
  smaller, slower, real-adapter-only suite that exercises the semantics
  directly.
- **In principle you can always simulate more.** You can teach a dummy
  about transactions, isolation, retries — the question is the price. In
  practice, once a dummy needs to model real concurrency or transaction
  semantics faithfully, it has become a second database. At that point
  write the real-adapter test instead.

The discipline is to keep the dummy *simple* and push exact-semantics
requirements into separate, explicit integration tests rather than letting
the dummy grow a full simulation.

## Dummies and Real Adapters Stack

Dual tests and ephemeral real instances (testcontainers, local Postgres,
embedded Redis, LocalStack) are not alternatives — they compose:

- **Dummy**: unit-speed feedback for both the interface contract suite
  and the business-logic tests that use the interface. Invoked frequently —
  on every save, every keystroke of TDD, every pre-push hook — because it
  is fast.
- **Testcontainer / real adapter**: runs the *same* interface contract
  suite and the *same* business-logic tests against the production
  adapter, plus any targeted exact-semantics tests. Invoked less
  frequently — locally when a developer wants full verification (before
  pushing, when finishing a task), and on every CI run.

The two tiers reinforce each other. The container run validates what the
dummy approximates; the dummy keeps iteration fast. Running business
logic against both is what keeps the dummy honest: if the dummy-backed
runs pass but the production-backed runs fail, the dummy has drifted and
must be fixed (or the abstract contract must be extended to pin the
missing behavior).

## Skipping vs. Failing

When the production adapter cannot run (no DB available, offline, etc.)
the production-backed runs — of both the interface contract suite and the
business-logic tests — are **skipped with an explicit marker**, not
silently turned off. Two properties follow:

- A developer without the environment set up, or iterating fast on BL,
  can run the full logic suite using dummies only.
- A full-verification run (on any machine with the environment, or in CI)
  executes the production leg and fails loudly if it is skipped when it
  shouldn't be.

Never delete production tests to make CI green; never replace them with
mock-based pseudo-integration tests.

## Avoiding Configuration Explosion

Running every test against every adapter against every business-logic
scenario would explode combinatorially. The dual-tests discipline contains
this:

- Integration points are **few and explicit** — one interface per external
  concern, not one per call site.
- Each test depends on **only the integration points it actually uses**
  and runs against the two implementations of *those* points only. A
  business-logic test that needs `UserRepository` runs twice (dummy +
  production), not 2^N times across every integration point in the system.
- Cross-cutting end-to-end scenarios are a separate, small, deliberately
  maintained suite — not a product of Cartesian multiplication over every
  integration point.

## Minimal Sketch

```
// The interface.
trait UserRepository {
    fn get(&self, id: UserId) -> Option<User>;
    fn put(&mut self, user: User);
}

// The abstract test suite — runs against ANY impl.
fn abstract_repo_tests<R: UserRepository>(mut make: impl FnMut() -> R) {
    // blackbox contract clauses
    let mut r = make();
    r.put(user("alice"));
    assert_eq!(r.get(id("alice")).unwrap().name, "alice");
    // ... more contract clauses
}

// Production adapter — real DB. Test skipped if DB unavailable.
#[test] #[requires_db]
fn postgres_repo_satisfies_contract() {
    abstract_repo_tests(|| PostgresUserRepository::connect(&test_db_url()));
}

// Dummy — in-memory. Always runs, fast.
#[test]
fn in_memory_repo_satisfies_contract() {
    abstract_repo_tests(|| InMemoryUserRepository::default());
}

// Business-logic tests are parameterized over the implementation, same
// as the interface contract suite. Both runs work anywhere the
// environment permits; developers invoke the dummy run frequently for
// speed and the production run for full verification.
fn abstract_signup_flow_tests<R: UserRepository>(mut make: impl FnMut() -> R) {
    let mut repo = make();
    // ... drive SignupService with `repo`, assert behavior
}

#[test]
fn signup_flow_against_dummy() {
    abstract_signup_flow_tests(|| InMemoryUserRepository::default());
}

#[test] #[requires_db]
fn signup_flow_against_postgres() {
    abstract_signup_flow_tests(|| PostgresUserRepository::connect(&test_db_url()));
}
```

## Relationship to the Taxonomy

In `constructive-test-taxonomy` terms:

- The **abstract test suite** is `Behavioral-Active-Blackbox` tests,
  parametric over the implementation.
- Running it against the **dummy** yields `Atomic` or `Group` tests — cheap,
  deterministic, run on every change.
- Running it against the **production adapter** yields
  `GoodCommunication` tests — more expensive, invoked less frequently
  (locally for full verification, always in CI), never skipped silently.
- **Business-logic tests** are parameterized over the interface and
  produce two labels depending on which implementation backs them: against
  the dummy they are `BA` / `BG` — the cheapest cell, where most fast-loop
  runs happen; against the production adapter they are
  `GoodCommunication` tests, invoked whenever full verification is
  wanted.

## Summary

- One interface per external concern.
- Tests that depend on the interface — both the contract suite and the
  business-logic tests — are parameterized over the implementation.
- Two implementations: production adapter + hand-written dummy.
- Run every such test against both; skip the production leg explicitly
  when the environment is unavailable.
- Running business logic against both is the forcing function that keeps
  dummies honest.
- Prefer dummies over auto-mocks.
- The distinction between dummy and production runs is **cadence, not
  venue**: both work anywhere the environment permits. Dummy-backed runs
  are invoked frequently for fast feedback; production-backed runs are
  invoked for full verification (locally when set up, always in CI).
