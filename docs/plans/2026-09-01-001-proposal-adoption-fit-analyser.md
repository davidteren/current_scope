# Proposal: a guided fit analyser that reads the adopter's app

**Status:** proposal, not scheduled. Written because the static comparison
(`docs/site/comparison.md`) answers "which library" but not "what would this
cost *me*, in *my* app".

## The gap

The comparison page ends with five questions and an honest cost table:
half a day for greenfield, one to four weeks of report-mode bake for a live app.
Both are generic. The questions a real adopter actually has are about their own
repository:

- How many `controller#action` pairs would become permissions, and how many of
  those are routes nobody should gate (health checks, webhooks, sign-in)?
- How much of their existing authorization is role-shaped, and how much is
  attribute-shaped? That single ratio decides whether this library fits at all,
  and today the adopter has to judge it by hand.
- Which models would want `current_scope_parent`, and how deep does that nest?
- Is the subject a plain integer id, or a UUID, or something composite?
- Which controllers already have a `before_action` that would need the gate
  skipped?

Every one of those is answerable by reading the repository. None of them needs a
person to answer a questionnaire about their own app.

## Shape

A page on the docs site, plus a small service behind it.

1. **Input.** A public repo URL, or an uploaded `routes.rb` + `Gemfile.lock` +
   the app's authorization files. Public-repo-only for the first cut: no
   credentials, no private code, nothing to store.
2. **Static pass first, LLM second.** Most of the value is deterministic and
   should not go near a model: parse the routes, count the pairs, group by
   controller, find the existing authorization gem in the lockfile, grep for
   `authorize`/`can?`/`policy`, read the primary key types from `schema.rb`.
   The LLM's job is the part that needs judgement: reading the existing policy
   objects and classifying each rule as **role-shaped** (a person's job title
   decides it), **record-shaped** (which record they hold decides it) or
   **attribute-shaped** (the record's data or the clock decides it).
3. **Output — a fit report, not a score.**
   - The ratio above, with the attribute-shaped rules quoted verbatim, because
     those are the ones that rule the library out.
   - A verdict that can be "use Action Policy" and says why.
   - If it fits: the permission count, the routes to exclude, the models that
     want a parent chain, the subject-identity decision, and a staged plan with
     the bake length argued from the app's own periodic work (a month-end job in
     the repo means a month-long bake).
   - A generated starter `config/initializers/current_scope.rb`.

## Why it is worth building

The library's own adoption risk is a host flipping `:enforce` on work their bake
never exercised. A tool that reads the repo and says "your bake must span
month-end, here is the job" attacks the one failure mode that
[#116](https://github.com/davidteren/current_scope/issues/116) exists to close.

It is also the honest form of marketing for a library whose best pitch is "here
is when not to use me": a tool that tells a third of its visitors to go and use
Action Policy is more persuasive than a comparison table that says the same
thing.

## Risks and rules

- **Never claim a fit it cannot support.** If the classifier is unsure, it says
  unsure and shows the code. A wrong "yes" costs an adopter weeks.
- **The static pass must stand alone.** If the model is unavailable, the report
  degrades to the counts and the checklist, and says so.
- **No private code, no retention, in the first cut.** Public repos, processed
  in memory, nothing written down.
- **Do not let it drift from the docs.** The staged plan it emits is the
  quickstart's ladder; if they disagree, the quickstart wins.

## Smallest useful first cut

A CLI in this repo — `bin/rails current_scope:fit` — that runs the static pass
against the host app it is installed in and prints the report. No service, no
LLM, no hosting. It answers the counting questions on day one, proves the
report's shape, and the hosted version becomes "the same thing, for a repo you
have not installed it into yet".
