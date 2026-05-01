### Batched clarification questions

When you need to ask the user **any non-trivial question**, or **more than three questions of any kind** (even trivial ones), do not pile them into a chat turn. Long or weighty question lists are tiring to answer, easy to skim, and easy to lose. Instead, write the questions to a draft file the user can fill in at their own pace.

#### When to apply

- You are about to ask **any non-trivial question** — one that requires judgment, context, a design decision, a tradeoff evaluation, or recall of prior decisions. A single non-trivial question is enough to use the file.
- You are about to ask **four or more questions of any kind** in a single turn, even if each one is individually trivial — the volume itself justifies the file.
- You have accumulated four or more open questions across an exploration or planning phase.
- The user explicitly asks for a written list of questions.
- Requirements are ambiguous along multiple independent axes (scope, data model, deployment, API shape, etc.) and resolving them inline would block progress.

A "trivial" question is one the user can answer reflexively without thinking — yes/no on a known preference, picking a name, confirming a path. Up to three trivial questions can stay inline. Anything that asks the user to weigh options, recall context, or commit to a direction is non-trivial and goes in the file.

#### Where to put the file

Follow the project documentation convention from the global guidelines: `./docs/drafts/{YYYYMMDD-HHMM}-questions-{topic}.md`.

- Use the local timezone `date +%Y%m%d-%H%M` for the prefix.
- `{topic}` is a short kebab-case slug describing the subject (e.g. `auth-rewrite`, `mqtt-controller-tass`).
- Create `./docs/drafts/` if it does not exist.
- If the project uses a different established docs layout, follow that layout instead — the filename convention still applies.

#### File format

Use this structure. Each question is a self-contained block with a stable ID so the user can reference answers by ID in chat or in the file itself.

```markdown
# Clarifications: {short subject}

**Context:** {1–3 sentences on why these questions exist — what task you are working on, what is blocking progress.}

**How to answer:** Write your response on the `Answer:` line under each question. Leave a question blank if you want to skip it. You can answer in any order; reference questions by their ID (e.g. `Q3`) in chat if convenient.

---

## Q1: {one-line question}

**Context:** {only if needed — what part of the code/spec/decision this touches, why it matters, what depends on it. Skip if the question is self-explanatory.}

**Suggestions:**
- {Option A — short label} — {one-line description, tradeoff, or consequence}
- {Option B — short label} — {one-line description, tradeoff, or consequence}
- {Option C ...}

Answer:

---

## Q2: {one-line question}

...

Answer:

---
```

Rules for the content:

- **IDs are stable**: number sequentially `Q1`, `Q2`, … and do not renumber if you add or remove questions later — append new IDs and mark removed ones as `~~Q3~~ withdrawn`.
- **One question per block**: do not bundle "and also" into a single question. Split it.
- **Suggestions are optional but encouraged**: when you have a recommended answer or a small set of plausible options, list them. Mark your recommendation with `(recommended)` and say briefly why. If the question is genuinely open-ended, omit the suggestions section rather than inventing options.
- **Context is optional**: skip the per-question `**Context:**` block when the question stands on its own. Use it when the user needs background to answer (links to files with `path:line`, prior decisions, constraints).
- **Answer line is mandatory and empty**: every question ends with a literal `Answer:` line followed by a blank line. Do not pre-fill it.
- **Neutral tone**: state the tradeoffs, do not lobby. The user decides.

#### After writing the file

1. Tell the user the path to the file and a one-line summary of what is in it. Do not paste the full file back into chat.
2. Stop and wait. Do not proceed with implementation while clarifications are open — that is the entire point of asking.
3. When the user returns answers (in chat or by editing the file), read the file, confirm your understanding of each answer in one or two lines, and only then proceed.
4. If new questions arise from the answers, append them to the same file with fresh IDs rather than starting a second file, unless the topic has clearly shifted.

#### What this skill is not

- Not a substitute for a design document — keep questions narrow and decision-shaped, not "explain the whole system to me."
- Not a place to dump every minor uncertainty — if you can resolve it by reading the code, do that first.
- Not a planning ledger — use tasks/plans for tracking work; this file is only for things that require a human decision.
