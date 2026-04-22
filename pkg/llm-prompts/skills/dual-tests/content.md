# Dual Tests

A concrete pattern that makes business logic testable in isolation from
external systems (databases, HTTP APIs, message queues, filesystems, clocks)
*without* giving up the ability to verify the real integration. A single
abstract test suite is written against an interface and then executed against
**two** implementations: the production adapter and a hand-written in-memory
dummy.

This is the mechanism that lets most of the suite sit in the cheap
**BA / BG** region — Behavioral-Active-Blackbox-Atomic/Group (see
`constructive-test-taxonomy`) — while still keeping a small, explicit set
of slow Communication-tier tests.

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
     developer, CI tier skipped), the production run is *skipped*, not
     faked. Dummy runs always execute.
5. **Use the dummy everywhere else.** Business-logic tests that need the
   interface instantiate the dummy directly — fast, deterministic, no
   external dependencies.

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

- **For business-logic tests, rough equivalence suffices.** Most logic only
  cares that writes are durable, reads see prior writes, and constraint
  violations surface as errors. A dummy can provide that cheaply, and 95%
  of the suite runs against it with a short feedback loop.
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

- **Dummy**: unit-speed feedback for the bulk of business logic. Runs on
  every save, every keystroke of TDD, every pre-push hook.
- **Testcontainer / real adapter**: verifies the production adapter
  actually satisfies the abstract suite, plus the small targeted tests for
  exact-semantics behavior. Runs in CI, possibly pre-merge, possibly only
  on nightly depending on cost.

Use dummies when feedback-loop length dominates. Use testcontainers when
you genuinely need to verify the adapter or exact-semantics behavior. The
two tiers reinforce each other: the container validates what the dummy
approximates, and the dummy keeps the inner dev loop fast.

## Skipping vs. Failing

When the production adapter cannot run (no DB available, offline, etc.) the
production leg of the abstract suite is **skipped with an explicit marker**,
not silently turned off. Two properties follow:

- Local dev and PR-time CI can run the full logic suite using dummies only.
- A higher CI tier (nightly, pre-release, or integration lane) runs the
  production leg and fails loudly if it is skipped when it shouldn't be.

Never delete production tests to make CI green; never replace them with
mock-based pseudo-integration tests.

## Avoiding Configuration Explosion

If you multiply N integration points × M configurations, the combinatorial
count of real-adapter tests explodes. The dual-tests discipline contains
this:

- Integration points are **few and explicit** — one interface per external
  concern, not one per call site.
- Production-leg tests exercise **the adapter in isolation**, not the
  adapter × the business logic. Business logic is exercised with dummies
  only.
- Cross-cutting scenarios (end-to-end) are a separate, small,
  deliberately-maintained suite — not a product of Cartesian multiplication.

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

// Business-logic tests use the dummy directly.
#[test]
fn signup_flow_rejects_duplicate_email() {
    let repo = InMemoryUserRepository::default();
    // ... drive SignupService with `repo`, assert behavior
}
```

## Relationship to the Taxonomy

In `constructive-test-taxonomy` terms:

- The **abstract test suite** is `Behavioral-Active-Blackbox` tests,
  parametric over the implementation.
- Running it against the **dummy** yields `Atomic` or `Group` tests — cheap,
  deterministic, run on every change.
- Running it against the **production adapter** yields
  `GoodCommunication` tests — more expensive, run on a separate tier, never
  skipped silently.
- **Business-logic tests** that consume the interface via the dummy stay
  `BA` / `BG` (Behavioral-Active-Blackbox-Atomic/Group) — the cheapest
  cell, where most of the suite should live.

## Summary

- One interface per external concern.
- One abstract test suite written against the interface.
- Two implementations: production adapter + hand-written dummy.
- Run the suite against both; skip production explicitly when unavailable.
- Prefer dummies over auto-mocks.
- Business logic is tested against the dummy only.
- This keeps the bulk of the suite in the cheap Blackbox-Atomic/Group cell
  while preserving a small, honest set of real-integration tests.
