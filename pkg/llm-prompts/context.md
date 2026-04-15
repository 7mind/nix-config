# Project Guidelines

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Core Principles

- **Think first**: Read existing files before writing code.
- **Concise output, thorough reasoning**: Be concise in what you write to the user; be thorough in what you think through.
- **Edit over rewrite**: Prefer editing over rewriting whole files.
- **No re-reads**: Don't re-read files you have already read.
- **Test before done**: Test your code before declaring it done.
- **No fluff**: No sycophantic openers or closing fluff.
- **Persistence**: Don't bail out partway through a task. If stuck, investigate, try a different angle, or ask — half-finished work is worse than none.
- **Fail fast**: Use assertions, throw errors early — no graceful fallbacks.
- **Explicit over implicit**: No default parameters or optional chaining for required values.
- **Minimal new comments**: Only write **new** comments to explain something non-obvious. Don't delete existing comments unless they're totally useless, wrong or out-of-date.
- **No workarounds**: Deliver sound, generic, universal solutions. When you discover a bug or problem, don't hide it — attempt to fix underlying issues, ask for assistance when you can't.
- **Ask questions**: When instructions or requirements are unclear, incomplete, or contradictory — always ask for clarifications before proceeding.
- **Recent versions**: Always use the most recent versions of the relevant libraries and tools.

## 2. References

- **RTFM**: Read documentation, code, and samples thoroughly, download docs when necessary, use search.
- **Prefer recent docs**: When searching, prioritize results from the current year over older sources.
- **Use available sources**: Explore package-manager caches when you need sources or docs that aren't in the project tree — `nix store`, cargo registry, npm cache, pip wheels, maven/coursier/ivy jars, etc.

## 3. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 4. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 5. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 6. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

## 7. Code Style

- **Type safety**: Encode domain concepts as named types (interfaces/classes/records), avoid catch-all types (Object, any) and untyped containers (string-keyed maps).
- **SOLID**: Adhere to SOLID principles.
- **No globals**: Pass dependencies explicitly via constructors, parameters, or DI containers — never rely on singletons, module-level mutable state, or ambient globals.
- **No magic constants**: Use named constants.
- **No backwards compatibility**: Refactor freely.
- **Composition over conditionals**: Prefer composition over conditional logic.
- **DRY**: Never duplicate, always generalize.

## 8. Project Structure

- **New docs**: When creating documentation in projects without an established docs layout, prefer `./docs/drafts/{YYYYMMDD-HHMM}-{name}.md`.
- **Debug scripts**: When creating throwaway debug scripts, prefer `./debug/{YYYYMMDD-HHMMSS}-{name}.{ext}` (use the appropriate extension for the project language).
- **Services**: Use interface + implementation pattern when possible.
- **Gitignore**: Always create and maintain reasonable `.gitignore` files.

## 9. Tools

- **Debuggers**: Use the debugger appropriate for the language at hand.
- **Parallelism**: Use `nproc` to determine available parallel processes.
- **Unattended mode**: Always run tools in batch mode, especially tools like SBT which expect user input by default.
