# izumi: distage + testkit + framework + docker + logstage + BIO

The izumi stack is a single coherent opinion: **describe the object graph
declaratively, let the planner build it, keep business logic effect-polymorphic
over BIO, inject a `LogIO2[F]` everywhere, switch environments via `Activation`
axes rather than by swapping modules, and reuse the same plugins in production
role apps and in `distage-testkit` tests so wiring is checked the same way
everywhere.**

Every rule below exists because drifting from it causes specific, named
failure modes — plugin scanning that silently finds nothing, containers that
get rebuilt once per test, dummies that don't get exercised, wiring errors
that only surface in production. Each section names the failure it prevents.

Reference repo throughout: <https://github.com/7mind/distage-example>
(the `bifunctor-tagless/` variant, branch `develop`). When in doubt about
a pattern, grep that module before inventing a new one.

---

## 1. distage core: ModuleDef discipline

### 1.1 Bind by intent, not by constructor

```scala
import distage.*

object AppModule extends ModuleDef {
  make[UserService]                                      // auto-wire constructor
  make[Clock].from(Clock.systemUTC _)                    // factory method
  make[AppConfig].fromValue(AppConfig.defaults)          // literal value
  make[HttpClient].fromResource(HttpClient.resource[F])  // Lifecycle / Resource
  make[Cache].fromEffect(F.sync(new Cache()))            // effectful ctor, no cleanup
  make[Database].todo                                    // placeholder, fails at plan time
}
```

**Rule:** Prefer `make[Iface].from[Impl]` for subtype binding over `make[Iface].from(new Impl(...))`. The planner derives the constructor; you get less drift when `Impl` gains dependencies.

**Failure it prevents:** manual `new Impl(a, b)` binding fails to compile next time `Impl` gains a parameter, but silently compiles and wires wrong when you bind `.from[Impl]` incorrectly — distage's constructor macro only accepts the single *primary* ctor, so adding a second constructor breaks the build early instead of hiding behind a manual lambda.

### 1.2 Named disambiguation

```scala
make[Byer].named("primary").from[PrintByer]
make[Byer].named("wrapped").from(wrappedByer _).annotateParameter[Byer]("primary")

// Consumer side — prefer @Id on the parameter over .annotateParameter on the binding:
class Router(@Id("primary") byer: Byer)
```

`@Id("name")` on the parameter is the idiomatic form. Reach for `.annotateParameter` only when you cannot modify the consumer.

### 1.3 Set bindings with weak refs

```scala
many[HttpApi[F]]
  .weak[LadderApi[F]]
  .weak[ProfileApi[F]]
```

`weak` means: *include this element only if some other strong root already pulls it into the plan.* This is how the example keeps `ProfileApi` out of the `ladder-only` role without maintaining two modules.

**Failure it prevents:** a strong `many[HttpApi[F]].add[LadderApi[F]]` drags `LadderApi` (and its `Profiles` dep) into every role, including `:configwriter`. `.weak` keeps the default role-slim and only materializes transitive deps when the role actually wants them.

### 1.4 Lifecycle for all cleanup

Never put `close()` in a destructor, finalizer, or `try/finally` inside a service. Always:

```scala
make[Connection].fromResource(
  Lifecycle.make(acquire)(c => F.sync(c.close()))
)
make[Pool].fromResource[Pool.Resource[F]]  // class extending Lifecycle
```

`Lifecycle.LiftF[F[Throwable, _], Iface[F]](for { ... } yield ifaceImpl)` is the canonical way to run one-time side effects (DDL, table creation, schema migrations) for a memoized instance — it runs **once per memoization scope**, which is exactly what tests and prod share.

### 1.5 Activation / Axis — how environments switch

Never duplicate modules to get `Prod` vs `Dummy`. Tag both bindings and pick at runtime:

```scala
import distage.StandardAxis.{Repo, Scene, Mode}

new ModuleDef {
  tag(Repo.Prod)
  make[Users[F]].fromResource[Users.Postgres[F]]
}
new ModuleDef {
  tag(Repo.Dummy)
  make[Users[F]].fromResource[Users.Dummy[F]]
}
```

Stock axes you should use:

| Axis | Values | Use for |
|------|--------|---------|
| `Repo` | `Prod` / `Dummy` | Stateful adapters (DB, cache, queue, FS) |
| `Scene` | `Managed` / `Provided` | Whether we spawn the infrastructure (testcontainer) or connect to an externally-managed one |
| `Mode` | `Prod` / `Test` | Coarse app mode (rarely needed if `Repo` and `Scene` already cover it) |
| `World` | `Real` / `Mock` | Third-party HTTP integrations |

**Rule of specificity:** a binding tagged with more axes wins over one tagged with fewer, when all tags match. An *untagged* default is chosen only if every more-specific alternative is contradicted.

### 1.6 GC roots and `SpecWiring`

distage plans are **garbage-collected from roots**. Only components transitively reachable from roots are instantiated. Provide roots explicitly:

```scala
Injector[IO]().produceGet[HttpServer[IO]](AppPlugin, activation = prodActivation)
```

Put a compile-time plan check next to the launcher. In `test/`:

```scala
final class WiringTest extends SpecWiring(GenericLauncher)   // example repo
// or
object WiringCheck extends PlanCheck.Main(MainLauncher)      // framework docs
```

**Failure it prevents:** a missing binding, cycle, or mis-tagged activation that would only blow up at prod startup. `PlanCheck` fails the build.

### 1.7 Tagless / bifunctor parameterization — `TagK`, `TagKK`

Every module that mentions `F[_]` or `F[_, _]` must request the tag:

```scala
def api[F[+_, +_]: TagKK]: ModuleDef = new ModuleDef {
  make[LadderApi[F]]
  make[Ranks[F]].from[Ranks.Impl[F]]
}
```

**Failure it prevents:** without `TagKK`, distage loses the higher-kinded type at runtime and you get `MissingInstanceException: F[E, A]` at first injection. The error is unhelpful; the fix is always a missing `: TagK` / `: TagKK`.

### 1.8 Config injection

```scala
import distage.config.ConfigModuleDef

object ConfigsModule extends ConfigModuleDef {
  makeConfig[PostgresCfg]("postgres")
  makeConfig[HttpCfg]("http")
}
```

HOCON layering is done by `distage-extension-config`: `application.conf`, `common-reference.conf`, `${roleId}-reference.conf`, CLI `-c file.conf`, role-scoped `:role -c file.conf`. Do not hand-roll `ConfigFactory.load()`.

### 1.9 Debugging a plan

```scala
val plan = Injector().plan(module, Roots.target[App]).getOrThrow()
println(plan.render())
println(plan.renderDeps(DIKey[Database]))
println(plan.renderDependees(DIKey[Transactor[IO]]))
```

GraphViz dump via bootstrap:

```scala
Injector(bootstrapOverrides = Seq(GraphDumpBootstrapModule)).produce(...)
// ./target/plan-last-nogc.gv, ./target/plan-last-full.gv
```

Macro debug flags (JVM `-D` or `sbt set`):

```
-Dizumi.debug.macro.rtti=true
-Dizumi.debug.macro.distage.constructors=true
-Dizumi.debug.macro.distage.functoid=true
```

---

## 2. distage-framework: RoleAppMain and plugins

### 2.1 One `PluginDef` per bounded context, assembled via `include`

```scala
object LeaderboardPlugin extends PluginDef {
  include(modules.roles[IO])
  include(modules.api[IO])
  include(modules.repoDummy[IO])     // tagged Repo.Dummy
  include(modules.repoProd[IO])      // tagged Repo.Prod
  include(modules.configs)
  include(modules.prodConfigs)       // tagged Scene.Provided
  include(BundledRolesModule[F[Throwable, _]](version = Version.parse("1.0.0")))
}
```

`BundledRolesModule` gives you `:help` and `:configwriter` for free.

**Separate** the docker plugin:

```scala
object PostgresDockerPlugin extends PluginDef {
  tag(Scene.Managed)
  include(DockerSupportModule[F[Throwable, _]])
  make[PostgresDocker.Container].fromResource(PostgresDocker.make[F[Throwable, _]])
  make[PostgresPortCfg].from { (c: PostgresDocker.Container) =>
    val a = c.availablePorts.first(DockerPort.TCP(5432))
    PostgresPortCfg(a.hostString, a.port)
  }
}
```

This way the docker cost is paid *only* under `Scene.Managed`.

### 2.2 The Launcher

```scala
sealed abstract class MainBase(activation: Activation, required: Vector[RoleArgs])
  extends RoleAppMain.LauncherBIO[IO] {

  override def requiredRoles(argv: RoleAppMain.ArgV) = required

  override def pluginConfig: PluginConfig =
    if (IzPlatform.isGraalNativeImage) PluginConfig.const(List(LeaderboardPlugin, PostgresDockerPlugin))
    else PluginConfig.cached(pluginsPackage = "leaderboard.plugins")

  override protected def roleAppBootOverrides(argv: RoleAppMain.ArgV): Module =
    super.roleAppBootOverrides(argv) ++ new ModuleDef {
      make[Activation].named("default").fromValue(Activation(Scene -> Scene.Provided) ++ activation)
    }
}

object MainProdDocker extends MainBase(Activation(Repo -> Repo.Prod,  Scene -> Scene.Managed),  Vector(RoleArgs(LeaderboardRole.id)))
object MainProd       extends MainBase(Activation(Repo -> Repo.Prod,  Scene -> Scene.Provided), Vector(RoleArgs(LeaderboardRole.id)))
object MainDummy      extends MainBase(Activation(Repo -> Repo.Dummy),                          Vector(RoleArgs(LeaderboardRole.id)))
```

**Rules:**
- GraalVM Native Image cannot use `ClassGraph` scanning — switch to `PluginConfig.const(...)` at runtime via `IzPlatform.isGraalNativeImage`. If you forget, the Native Image silently finds zero plugins.
- Roles are **not** auto-added by plugin discovery; they're requested on the command line (`./launcher :leaderboard`) or hard-coded via `requiredRoles` / a Main object.
- Inject default `Activation` in `roleAppBootOverrides` — that's the only place it's safe to override; CLI `-u repo:dummy` still composes on top of it.

### 2.3 `RoleService` vs `RoleTask`

- `RoleService[F]` — long-running daemon. Acquire resources, start server, return. Shutdown runs when the app is interrupted.
- `RoleTask[F]` — one-shot task. Runs, returns, app exits.

Both have `start(roleParameters: EntrypointArgs): F[...]`. Bind with `makeRole[X]` inside a `RoleModuleDef`.

### 2.4 Plugins in their own module

Put plugins in a dedicated sbt module (or at least a separate package) so `PluginConfig.cached(packagesEnabled = Seq("x.y.plugins"))` scans a small, predictable surface and so the compile-time `SpecWiring` check can actually resolve them.

**Anti-pattern:** defining `PluginDef`s in the same file as the launcher. `SpecWiring` won't find them and will report the graph as empty.

---

## 3. distage-testkit: write the test once, run it twice

### 3.1 Base class by effect shape

| Effect | Base | Assert |
|--------|------|--------|
| No effect | `SpecIdentity` | raw ScalaTest asserts |
| `F[_]` (cats IO) | `Spec1[IO]` | `AssertCIO` |
| `F[+_, +_]` (BIO) | `Spec2[F]` | `AssertIO2` |
| `ZIO` with env | `SpecZIO` | `AssertZIO` |

### 3.2 `TestConfig` is the whole story

```scala
abstract class LeaderboardTest extends SpecZIO with AssertZIO {
  override def config: TestConfig = super.config.copy(
    pluginConfig    = PluginConfig.cached(packagesEnabled = Seq("leaderboard.plugins")),
    moduleOverrides = super.config.moduleOverrides ++ new ModuleDef {
      make[Rnd[IO]].from[Rnd.Impl[IO]]   // test-only helper
    },
    activation      = Activation(Scene -> Scene.Managed),
    memoizationRoots = Set(
      DIKey[Ladder[IO]],
      DIKey[Profiles[IO]],
    ),
  )
}
```

**The five knobs that matter:**

- `pluginConfig` — same plugins as prod. Reuse the launcher's plugin package; do not fabricate a test-only module graph.
- `moduleOverrides` — small deltas only (inject a test `Rnd`, a deterministic clock). Not a parallel universe.
- `activation` — swap `Repo.Prod` ↔ `Repo.Dummy`, `Scene.Managed` ↔ `Scene.Provided`.
- `memoizationRoots` — the set of `DIKey`s whose transitive graph is instantiated **once per memoization env** and shared across every test in the env. Put the container + any expensive resource here.
- `parallelLevel` — default is parallel; flip to `Parallelism.Sequential` only when tests share an unguarded global.

### 3.3 Memoization: one env = `(memoizationRoots, activation, pluginConfig, moduleOverrides, forcedRoots)`

Change any tuple element and you get a fresh environment — a fresh docker container, a fresh HikariCP pool, fresh DDL. So:

- **Put the container as a transitive dep of your `memoizationRoots`** (the example roots `Ladder[IO]` and `Profiles[IO]`; the `PostgresDocker.Container` is pulled in transitively), and it lives for the whole suite.
- **Don't change activation mid-suite.** Split into two test classes with a trait each — that is the expected way to get both runs.

### 3.4 Dual-tests shape (see §7 for the full pattern)

```scala
abstract class LadderTest extends LeaderboardTest {
  "submitScore & getScores" in { (rnd: Rnd[IO], ladder: Ladder[IO]) =>
    for {
      id    <- rnd[UserId]
      score <- rnd[Score]
      _     <- ladder.submitScore(id, score).orTerminate
      out   <- ladder.getScores.map(_.toMap).orTerminate
      _     <- assertIO(out.get(id).contains(score))
    } yield ()
  }
}

trait DummyTest extends LeaderboardTest {
  override final def config = super.config.copy(
    activation = super.config.activation ++ Activation(Repo -> Repo.Dummy)
  )
}
trait ProdTest extends LeaderboardTest {
  override final def config = super.config.copy(
    activation = super.config.activation ++ Activation(Repo -> Repo.Prod)
  )
}

final class LadderTestDummy    extends LadderTest with DummyTest
final class LadderTestPostgres extends LadderTest with ProdTest
```

`SpecWiring` as a separate sibling class verifies that the **prod role graph** wires without running a single test.

### 3.5 Test-body shapes

```scala
"one"   in { assert(1 + 1 == 2) }                                  // plain
"two"   in { (cfg: Config) => assert(cfg.ok) }                     // inject deps
"three" in { (r: Repo[IO]) => r.get("x").as(assertIO(true)) }      // inject + effect
"four"  in { ranks.getRank(id).flatMap(r => assertIO(r.isDefined)) } // ZIO env accessor
```

For ZIO env style, collect the accessors in a `zioenv.scala`:
```scala
object ranks { def getRank(u: UserId): URIO[Ranks[IO], ...] = ZIO.serviceWithZIO[Ranks[IO]](_.getRank(u)) }
```

---

## 4. distage-framework-docker: containers as graph nodes

### 4.1 Declare the container

```scala
object PostgresDocker extends ContainerDef {
  val primaryPort: DockerPort = DockerPort.TCP(5432)
  override def config: Config = Config(
    image = "postgres:15",
    ports = Seq(primaryPort),
    env   = Map("POSTGRES_PASSWORD" -> "postgres"),
  )
}
```

### 4.2 Three things to bind together

```scala
tag(Scene.Managed)
include(DockerSupportModule[F[Throwable, _]])                  // brings DockerClientWrapper
make[PostgresDocker.Container].fromResource(PostgresDocker.make[F[Throwable, _]])
make[PostgresPortCfg].from { (c: PostgresDocker.Container) =>
  val a = c.availablePorts.first(PostgresDocker.primaryPort)
  PostgresPortCfg(a.hostString, a.port)
}
```

**Rule:** the container's mapped port is dynamic; rewrite your JDBC URL (or similar config) from `container.availablePorts` rather than hard-coding. The example uses `PostgresPortCfg.substitute("jdbc:postgresql://{host}:{port}/postgres")`.

**Failure it prevents:** forgetting `DockerSupportModule` → `MissingInstanceException[DockerClientWrapper]` at plan time.

### 4.3 Reuse, networks, integration-check

- Container reuse is on by default (`ReuseEnabled`) — distage-docker reuses a matching running container across test processes and across CI shards. Do not fight this.
- Networks: `ContainerNetworkDef` + `.connectToNetwork(Net)` + `.dependOnContainer(OtherDef)` to express startup order in multi-container setups.
- **Integration check** for "is the port actually accepting connections?" — wrap the transactor in a `Lifecycle.OfCats(...)` that also extends `IntegrationCheck[F]` and implements `resourcesAvailable()` using `PortCheck.checkPort(...)`. Tests are *cancelled* (not failed) if the check fails — that's how the dummy-only CI leg stays green when Docker is unavailable.

### 4.4 Memoize the container

From §3.3: put a leaf that transitively needs the container (`Ladder[IO]`, `Profiles[IO]`, or the `Transactor` itself) into `memoizationRoots`. Docker start-up happens once per suite env, not once per `in { ... }`.

---

## 5. LogStage: structured logging with named fields

### 5.1 The interpolator preserves names

```scala
logger.info(s"user=$userId submitted score=$score")
// JSON: {"event":"...","user":"u-42","score":17,...}
```

The macro captures variable names. Do **not** use positional mocks-of-SLF4J style:

```scala
logger.info(s"user={} value={}", userId, score)   // loses names, defeats the point
```

Named expressions override capture: `log"ask ${Random.nextInt() -> "chosen"}"`. Hidden expressions: `log"... ${secret -> "secret" -> null}"` (key-only, value suppressed).

### 5.2 Inject `LogIO2[F]` (or `LogIO[F]`) everywhere

Effect-polymorphic services depend on the logger typeclass:

```scala
final class Postgres[F[+_, +_]: Monad2](sql: SQL[F], log: LogIO2[F]) extends ...
```

distage-framework wires `LogIO2[F]` for you — no explicit binding in user plugins. For `cats.effect.IO`, ask for `LogIO[F]`; for ZIO env style, `LogZIO` / `URIO[LogZIO, _]`.

### 5.3 Contextual logs

```scala
val scoped = log.withCustomContext("userId" -> id, "op" -> "submit")
scoped.info(s"processing")    // context fields appended to every message
```

### 5.4 Configure sinks in HOCON, not in code

```hocon
logger {
  levels = { "leaderboard.repo" = "debug" }
  json   = false
}
```

Two canonical sinks: `ConsoleSink.text(colored = true)` for humans, `ConsoleSink(LogstageCirceRenderingPolicy())` for ELK/Loki. Wire both for local dev + JSON-only for prod via Activation.

### 5.5 SLF4J bridge

```scala
import izumi.logstage.api.routing.StaticLogRouter
StaticLogRouter.instance.setup(logger.router)
```

Add `logstage-adapter-slf4j` to the classpath so library logs (doobie, http4s, hikari) flow through logstage and inherit the level config.

### 5.6 Anti-patterns

- Calling `LoggerFactory.getLogger` directly inside a distage-managed service.
- Building a logger manually in a `val` at class scope — bypasses wiring and DI-controlled context.
- Using `s"..."` string interpolation without the `log` prefix — it works, but forfeits structure in JSON mode; prefer `log"..."` when you want fields.

---

## 6. BIO: bifunctor effect typeclasses

### 6.1 Why

`F[+E, +A]` (and `F[-R, +E, +A]`) separates *declared errors* from *defects*. ZIO 2 has this natively; `cats.effect.IO` does not. BIO is the single vocabulary you use in polymorphic code so services can be instantiated at either.

### 6.2 The typeclass ladder

From weakest to strongest:
`Functor2` → `Bifunctor2` → `Applicative2` → `Monad2` → `Error2` → `Bracket2` → `Panic2` → `IO2` → `Async2` → `Temporal2` → `Concurrent2` → `Parallel2`.

Plus `Primitives2` (refs, promises, semaphores) — independent orthogonal capability.

**Rule:** constrain on the *weakest* typeclass that compiles. `Monad2` is the default for business logic; use `IO2` only when you actually call `F.sync { ... }`; use `Primitives2` only when you need `F.mkRef` / promises.

### 6.3 Effect-polymorphic service

```scala
import izumi.functional.bio.{Monad2, Primitives2, Applicative2, F}

final class Ladder.Dummy[F[+_, +_]: Applicative2: Primitives2] extends Lifecycle.LiftF[F[Throwable, _], Ladder[F]](
  for { state <- F.mkRef(Map.empty[UserId, Score]) } yield new Ladder[F] {
    def submitScore(id: UserId, s: Score): F[QueryFailure, Unit] =
      state.update_(_.updated(id, s))
    def getScores: F[QueryFailure, List[(UserId, Score)]] =
      state.get.map(_.toList.sortBy(-_._2.value))
  }
)
```

### 6.4 Interop

```scala
import izumi.functional.bio.catz.*   // materialize cats.effect.Async / Sync from BIO
```

This is how http4s and doobie route calls receive `Async[F[Throwable, _]]` without the service caring. Do not import `cats.effect.*` typeclasses directly into a BIO service.

### 6.5 Mixing logger with effect

```scala
def process[F[+_, +_]: Monad2: LogIO2]: F[Nothing, Unit] =
  for {
    _ <- LogIO2[F].info(s"starting")
    _ <- ...
  } yield ()
```

### 6.6 Error handling idioms

```scala
F.fromEither(either)                  // Either -> F[E, A]
effect.attempt                        // F[E, A] -> F[Nothing, Either[E, A]]
F.bracket(acquire)(release)(use)      // resource-safe
F.parTraverse(items)(step)            // parallel
effect.sandbox                        // surface defects alongside typed errors
```

### 6.7 Anti-patterns

- Mixing typed errors (`F[E, A]`) with unchecked exceptions in the same pipeline — either lift to `E` at the boundary or `.sandbox`.
- Using `Panic2` for recoverable failures (it's for defects/cleanup).
- Constraining every function with `IO2` — you lose testability; most logic needs only `Monad2` (+ `Error2` if it fails).
- Binding `F[Throwable, _]` into distage without `: TagKK` on the module.

---

## 7. Dual-tests with distage — the canonical implementation

This is the reason the whole stack is shaped the way it is. The abstract
`dual-tests` pattern (see the `dual-tests` skill) says: one interface, one
abstract test suite, two implementations (Prod adapter + hand-written
in-memory Dummy), run the suite against both, skip the Prod leg explicitly
when the environment is unavailable. distage makes this a two-axis swap.

### 7.1 The layout

```
leaderboard/
  repo/
    Ladder.scala          // trait Ladder[F[_, _]] + companion with Dummy, Postgres
  plugins/
    LeaderboardPlugin.scala   // tag(Repo.Prod) -> Postgres, tag(Repo.Dummy) -> Dummy
  test/
    LadderTest.scala          // abstract class — the contract + BL tests
    LadderTestDummy.scala     // extends LadderTest with DummyTest
    LadderTestPostgres.scala  // extends LadderTest with ProdTest
```

### 7.2 The interface

```scala
trait Ladder[F[_, _]] {
  def submitScore(id: UserId, score: Score): F[QueryFailure, Unit]
  def getScores: F[QueryFailure, List[(UserId, Score)]]
}

object Ladder {
  final class Dummy[F[+_, +_]: Applicative2: Primitives2] extends Lifecycle.LiftF[...](...)
  final class Postgres[F[+_, +_]: Monad2](sql: SQL[F], log: LogIO2[F]) extends Lifecycle.LiftF[...](...)
}
```

### 7.3 The plugin — tag, don't branch

```scala
def repoDummy[F[+_, +_]: TagKK: Applicative2: Primitives2]: ModuleDef = new ModuleDef {
  tag(Repo.Dummy)
  make[Ladder[F]].fromResource[Ladder.Dummy[F]]
  make[Profiles[F]].fromResource[Profiles.Dummy[F]]
}

def repoProd[F[+_, +_]: TagKK: Monad2]: ModuleDef = new ModuleDef {
  tag(Repo.Prod)
  make[Ladder[F]].fromResource[Ladder.Postgres[F]]
  make[Profiles[F]].fromResource[Profiles.Postgres[F]]
  make[SQL[F]].from[SQL.Impl[F]]
  make[PortCheck].from(new PortCheck(3.seconds))
  include(TransactorPlugin[F])        // contributes Transactor + IntegrationCheck
}

object LeaderboardPlugin extends PluginDef {
  include(modules.repoDummy[IO])
  include(modules.repoProd[IO])
  ...
}
```

Both modules are **always present** in the graph. `Activation(Repo -> Dummy)` or `(Repo -> Prod)` makes the planner GC the other half away.

### 7.4 The abstract test — one body, blackbox, active

```scala
abstract class LadderTest extends LeaderboardTest {
  "Ladder" should {
    "persist and return scores in descending order" in {
      (rnd: Rnd[IO], ladder: Ladder[IO]) =>
        for {
          u1 <- rnd[UserId]; u2 <- rnd[UserId]
          _  <- ladder.submitScore(u1, Score(10)).orTerminate
          _  <- ladder.submitScore(u2, Score(20)).orTerminate
          out <- ladder.getScores.orTerminate
          _   <- assertIO(out.map(_._1) == List(u2, u1))
        } yield ()
    }

    "reject duplicates or overwrite last-write-wins" in { ... }
    // ... the full contract for Ladder
  }
}
```

This is **blackbox, active, atomic/group** in taxonomy terms (see `constructive-test-taxonomy`). It makes **no assumption** about dummy vs. prod.

### 7.5 The two concrete classes — just swap activation

```scala
trait DummyTest extends LeaderboardTest {
  override final def config = super.config.copy(
    activation = super.config.activation ++ Activation(Repo -> Repo.Dummy)
  )
}
trait ProdTest extends LeaderboardTest {
  override final def config = super.config.copy(
    activation = super.config.activation ++ Activation(Repo -> Repo.Prod)
  )
}

final class LadderTestDummy    extends LadderTest with DummyTest
final class LadderTestPostgres extends LadderTest with ProdTest
```

### 7.6 How it lines up with the abstract dual-tests skill

| dual-tests skill says | distage implementation |
|------------------------|-------------------------|
| One interface per external concern | `trait Ladder[F[_, _]]` |
| Hand-written dummy, not auto-mock | `Ladder.Dummy[F]` — a real `Lifecycle.LiftF` built on `Primitives2.mkRef` |
| Abstract test suite parametric over impl | `abstract class LadderTest` — deps injected from the graph |
| Run it against both impls | `LadderTestDummy` + `LadderTestPostgres` |
| Skip prod when env unavailable | `IntegrationCheck.resourcesAvailable()` cancels the test, does not fake it |
| BL tests also parameterized | Same shape — `RanksTest`, `ProfilesTest` each have `*Dummy` and `*Postgres` twins |
| Dummy for fast loop; prod for full verification | sbt aliases: `testDummy` runs `*Dummy`, CI runs the lot |
| Dummy must be kept honest | Identical test body + identical `Activation`-gated plugin = any drift between Dummy and Postgres is a *test* failure, not a prod surprise |

### 7.7 Where leaks happen, and where they don't

The pattern only works while the interface is narrow. When a service needs
`SELECT ... FOR UPDATE`, a vendor-specific upsert, or a `Panic2`-level
transaction primitive, **promote it to its own narrow interface**
(`trait TransactionalLadder[F] extends Ladder[F]`), write a cruder dummy for
*that* interface, and let a small minority of tests be `GoodCommunication`
tests that run only against Postgres. Do not let the leak spread into
`Profiles`, `Ranks`, etc.

### 7.8 What to do when the dummy drifts

If `LadderTestDummy` passes but `LadderTestPostgres` fails on the same case:

1. The **contract** is incomplete — the test exposes a behavior you didn't pin down. Extend `LadderTest` with a new clause that would have caught the drift.
2. Fix the **dummy** to satisfy the extended contract.
3. Confirm both run green.

Never "fix" drift by making the test implementation-specific, and never delete the failing leg.

---

## 8. Adding a new business service — the walkthrough

Using `Ranks` (services/Ranks.scala) as the template. Order matters.

1. **Define the interface in `services/` or `repo/`** (depending on whether it is stateless business logic or an external-state adapter):
   ```scala
   trait Ranks[F[_, _]] {
     def getRank(u: UserId): F[QueryFailure, Option[RankedProfile]]
   }
   ```

2. **Write the implementation in the companion.** For an external adapter, write both `.Dummy` and `.Postgres`; for a pure service, one `.Impl` is enough:
   ```scala
   object Ranks {
     final class Impl[F[+_, +_]: Monad2](ladder: Ladder[F], profiles: Profiles[F]) extends Ranks[F] { ... }
   }
   ```

3. **Bind in the plugin.** If it's a pure service, bind in `api`; if it has Prod/Dummy variants, bind each in its tagged module:
   ```scala
   // in modules.api[F]
   make[Ranks[F]].from[Ranks.Impl[F]]
   ```

4. **Write the abstract test.** `abstract class RanksTest extends LeaderboardTest` with injected-dependency test bodies. Pure services still benefit from being parameterized over their *dependencies*' `Activation` — running `RanksTest` against `Repo.Dummy` and `Repo.Prod` exercises the transitive integration.

5. **Create the two concrete subclasses** — `RanksTestDummy extends RanksTest with DummyTest`, `RanksTestPostgres extends RanksTest with ProdTest`.

6. **(Optional) Add a ZIO env accessor** in `zioenv.scala` for the test ergonomics:
   ```scala
   object ranks { def getRank(u: UserId) = ZIO.serviceWithZIO[Ranks[IO]](_.getRank(u)) }
   ```

7. **Rerun `WiringTest`/`SpecWiring`** — confirms the prod role still wires.

Every step above touches at most one file per concern. Anything that makes you
edit six files is a sign you are bypassing the tag/activation mechanism.

---

## 9. Anti-patterns and failure-mode index

**distage core**
- Manual `new Impl(dep1, dep2)` bindings instead of `make[Iface].from[Impl]`. Silent drift when `Impl` gains deps.
- Constructing global singletons outside the graph. Breaks activation-based swaps; dummy version never gets used.
- Mutable ambient state (`object Cache extends ...`). Identical defect; also poisons parallel tests.
- Missing `: TagK` / `: TagKK` on polymorphic modules. `MissingInstanceException` at runtime with unhelpful HK-type name.
- Using `.fromEffect` for something that needs cleanup. Resource leaks. Use `.fromResource`.
- Putting multiple ctors on a class meant for auto-wire. Planner can't pick.

**Activation / Axis**
- Duplicating two plugins to get Prod vs Dummy. Bindings drift, you forget to keep both in sync. Use tags instead.
- Branching on a flag inside a binding (`if (prod) ... else ...`). Same problem. Tag the whole binding.
- Forgetting a default (untagged) binding when some code path is axis-insensitive. `ConflictingBindingsException` at plan time.

**Plugins / Framework**
- Defining `PluginDef` in the same module as `SpecWiring` check. `ClassGraph` may not see them; wiring test passes on empty graph.
- `PluginConfig.cached(...)` under GraalVM Native Image. Zero plugins discovered at runtime. Guard with `IzPlatform.isGraalNativeImage` and fall back to `.const(...)`.
- Registering the docker module unconditionally. Pays Docker daemon cost in prod. Tag `Scene.Managed`.
- Forgetting `BundledRolesModule`. No `:help`, no `:configwriter`.

**Testkit**
- Changing `Activation` or `moduleOverrides` per-test. Each test becomes its own memoization env; container rebuilt every time.
- Putting containers outside the memoization-root closure. Same symptom.
- Running prod and dummy variants in the same test class via conditionals. Loses the parallelism, defeats the dual-tests discipline.
- Silently skipping the Postgres leg in CI when Docker is down. The suite passes on half of what it should. Use `IntegrationCheck` so the framework marks tests *cancelled*, not *passed*.
- Rebinding core services only in tests (test-only module graph). What you test is not what you ship. Use `moduleOverrides` for test-only helpers (`Rnd`, deterministic `Clock`), not to replace production bindings.

**Docker**
- Hard-coding host/port in connection URL. Breaks the moment mapped ports change. Build the URL from `container.availablePorts.first(...)`.
- Skipping `DockerSupportModule`. `MissingInstanceException[DockerClientWrapper]`.
- Custom start-up wait loops instead of `IntegrationCheck`. Races under CI load.

**LogStage**
- `s"..."` instead of `log"..."` in JSON mode. Loses field structure.
- Calling `LoggerFactory.getLogger` or constructing `IzLogger` manually inside a DI-managed service. Bypasses context and sink config.
- Positional-substitution SLF4J style. Same field-loss defect.

**BIO**
- Constraining on `IO2`/`Async2` when `Monad2` suffices. Harder to test; forces a concrete runtime.
- Forgetting `import izumi.functional.bio.catz.*` when integrating cats-libs (http4s, doobie). `Async[F[Throwable, _]]` implicit not found.
- Mixing `throw` inside `F.sync` without `.sandbox`. Defects bypass typed error channels.
- Binding `F[Throwable, _]` in a ModuleDef lacking `: TagKK`. Runtime wiring error, see §1.7.

---

## 10. Reference — files worth opening in `distage-example`

When implementing any of the patterns above, open the equivalent file in the
example rather than inventing a new layout:

- Launcher + Main objects: `bifunctor-tagless/src/main/scala/leaderboard/LeaderboardRole.scala`
- Plugin composition: `.../plugins/LeaderboardPlugin.scala`
- Docker plugin: `.../plugins/PostgresDockerPlugin.scala`
- Repo interface + Dummy + Postgres: `.../repo/Ladder.scala`, `.../repo/Profiles.scala`
- Pure service: `.../services/Ranks.scala`
- SQL layer + integration check: `.../sql/SQL.scala`, `.../sql/TransactorResource.scala`
- HTTP (http4s via BIO): `.../http/HttpServer.scala`, `.../api/LadderApi.scala`
- Dual tests: `bifunctor-tagless/src/test/scala/leaderboard/tests.scala`
- Compile-time wiring check: `bifunctor-tagless/src/test/scala/leaderboard/WiringTest.scala`
- ZIO env accessors: `bifunctor-tagless/src/test/scala/leaderboard/zioenv.scala`
- Build: `build.sbt`, `common-reference.conf`

Izumi docs (in this repo): `doc/microsite/src/main/tut/{distage,logstage,bio}/*.md`.

---

## 11. Quick decision table

| Situation | Do this |
|-----------|---------|
| New external dependency | Interface + Prod adapter + Dummy; tag with `Repo`; dual-tests |
| Infrastructure we may or may not spawn | Tag `Scene.Managed` vs `Scene.Provided`; docker plugin under Managed |
| Need cleanup | `Lifecycle.fromResource` / `Lifecycle.LiftF`, never finalizers |
| Sharing one Postgres across the whole test suite | Put a transitive dep into `memoizationRoots` |
| Polymorphic effect | `F[+_, +_]: Monad2` (+ `Error2` if it fails, + `Primitives2` if it needs refs) |
| Per-request logger context | `log.withCustomContext(...)` |
| Need to see the object graph | `Injector().plan(...).render()` or GraphViz bootstrap |
| GraalVM Native Image | `PluginConfig.const(...)` guarded by `IzPlatform.isGraalNativeImage` |
| "It passes on Dummy but not Postgres" | Contract is incomplete — extend the abstract test, fix the dummy; never weaken the test |
