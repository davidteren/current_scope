---
title: "SimpleCov reports a number that is quietly wrong: load order and filter anchoring"
module: test/coverage_setup.rb
date: 2026-08-23
problem_type: workflow_issue
component: testing_framework
severity: medium
applies_when:
  - "Adding SimpleCov to a Rails engine, or to any gem with a dummy app"
  - "Starting SimpleCov from test_helper.rb rather than from the test binary"
  - "Writing any SimpleCov `skip`, `add_filter`, `cover`, or `add_group` pattern"
  - "Reviewing a coverage percentage that moved without the tests changing"
  - "Reading a code comment that states a measured coverage figure"
symptoms:
  - "Coverage collapses to roughly a third of the real figure, with a green suite"
  - "A whole directory reports 0% while its lines still count in the denominator"
  - "A `skip` or `add_filter` pattern has no effect and raises nothing"
  - "One filter works and its neighbour silently does not, for no visible reason"
  - "The percentage rises after a filter change, and the change looks unrelated"
root_cause: config_error
resolution_type: test_fix
related_components:
  - testing_framework
  - "test/coverage_setup.rb"
  - "test/coverage_setup_test.rb"
  - "bin/rails"
tags:
  - simplecov
  - coverage
  - load-order
  - regexp-anchoring
  - silent-failure
  - tooling
  - ruby-coverage
related_issues:
  - "#114 (closed): add a SimpleCov coverage signal to CI (worklist T6)"
  - "#145 (merged): start SimpleCov before the engine loads, so coverage measures lib/"
  - "#146 (closed, PR #173): the CI coverage floor that now depends on this being right"
  - "#147 (this entry): recommended by the learnings reviewer across two passes on #145"
---

## Context

Coverage tooling has one job: report a number. Both traps below break that job in
the same way. Nothing fails, nothing raises, and the number is just quietly wrong.
A green suite is not evidence against either of them, because neither has anything
to do with the tests.

Both bit during #145, and the second one bit twice in the same pull request.

## Trap 1: Ruby's Coverage cannot instrument a file that is already loaded

`Coverage.start` hooks compilation. A file compiled before that call is invisible
to it forever. There is no retroactive mode and no warning.

The bootstrap originally ran from `test/test_helper.rb`. By the time Ruby reached
that line, the test command's prepare step had already booted the dummy app and
the engine, so every file under `lib/` was loaded. SimpleCov's `cover` glob still
put those files in the denominator, and Coverage had nothing to say about them, so
they reported 0%.

The result, as measured in #145: **34.95% reported against a real figure of
97.40%.** The suite was green throughout. The number was wrong by a factor of
nearly three, and nothing in the run said so.

The fix moves the bootstrap to the earliest point that still knows a test is being
run. In `bin/rails`, that is above the require that pulls in the engine:

```ruby
require_relative "../test/coverage_setup" if ARGV.first&.match?(/\A(t|test)(:|\z)/)

require "rails/all"
require "rails/engine/commands"
```

`test/test_helper.rb` requires it too, because `ruby -Itest test/foo_test.rb` and
some IDE runners never touch `bin/rails`. `require_relative` is idempotent, so
whichever entry point comes first starts SimpleCov and the other is a no-op.

Two details in that file are load-order consequences rather than style:

**The file is not called `coverage.rb`.** `ruby -Itest` puts `test/` on the load
path, and SimpleCov itself calls `require "coverage"` to load the stdlib
extension that does the measuring. A `test/coverage.rb` wins that lookup, SimpleCov
gets this file back instead of the extension, and it dies on
`uninitialized constant SimpleCov::Coverage`.

**The guard raises a plain `RuntimeError`, not `CurrentScope::ConfigurationError`.**
This file runs before the engine is loaded, so that class does not exist yet.

## Trap 2: SimpleCov filters match a path with no leading slash

SimpleCov matches String, Regexp and glob filters against `project_filename`,
not against the absolute path. (A block filter is the exception: it receives the
whole `SourceFile` and can read the absolute name.) In simplecov 1.1.1,
`lib/simplecov/source_file.rb`:

```ruby
def project_filename
  @filename.delete_prefix(SimpleCov.root).sub(%r{\A[/\\]}, "")
end
```

That `sub` is the whole trap. The value is root-relative **and the leading slash
is explicitly stripped**, so the string a `RegexFilter` sees is
`"lib/current_scope/version.rb"`, never `"/lib/current_scope/version.rb"`.

`RegexFilter#matches?` is an unanchored `match?`, so a pattern is free to match
anywhere in that string:

```ruby
def matches?(source_file)
  filter_argument.match?(source_file.project_filename)
end
```

A pattern that does not match filters nothing. It raises nothing, warns nothing,
and leaves a percentage that looks plausible.

### The part that makes it sharp: a dead filter looks correct because its sibling works

Because the match is unanchored, a leading slash is harmless **in the middle** of
a path and fatal **at the root**. Checked against the two real paths in this repo:

| Pattern | `lib/current_scope/version.rb` | `lib/generators/.../templates/initializer.rb` |
|---|---|---|
| `%r{/lib/current_scope/version\.rb\z}` | no match | no match |
| `%r{\Alib/current_scope/version\.rb\z}` | **match** | no match |
| `%r{/generators/.*/templates/}` | no match | **match** |
| `%r{\Alib/generators/.*/templates/}` | no match | **match** |

The generator filter works with a leading slash, because `/generators/` really
does appear inside `lib/generators/...`. The `version.rb` filter written the same
way matches nothing at all, because `lib/` sits at position 0 with nothing before
it. Two filters written in the same style, side by side, one live and one dead.

That is why this was written wrong twice in one pull request. The house style
looked confirmed by the filter that happened to work.

The rule is one line, and it is about **Regexp** arguments only:
**anchor a Regexp filter with `\A`, and never lead with a slash.**

It does not carry over to the other two argument types, and applying it there
produces the same silent failure. A String argument is a path-segment match, not
a Regexp. A String passed to `cover` is a shell glob, where `\A` is four literal
characters that match nothing. This entry's own `cover "{app,lib}/**/*.rb"` is a
glob, and correctly carries no anchor.

### The third instance of the same shape, in the opposite direction

`cover` must stay a String glob, and `test/coverage_setup_test.rb` asserts that:

```ruby
assert SimpleCov.cover_globs.any?, "cover must be configured with a string glob"
```

Only globs drive SimpleCov's unloaded-file injection. An equivalent `Regexp`
would silently drop never-loaded files out of the denominator, which **raises**
the reported percentage. Same silent failure, opposite direction, and the
direction that flatters you is the one nobody investigates.

## Guidance

**Treat a coverage percentage as an unverified claim until something in the repo
fails when it goes wrong.** Three mechanisms, and this repo now has all three.

**1. Guard the ordering where the ordering lives.** `test/coverage_setup.rb`
raises if the engine is already loaded when it runs:

```ruby
if defined?(CurrentScope::Engine)
  raise "Coverage bootstrap ran too late: ..."
end
```

Keep that block **above** `require "simplecov"`. `test/coverage_setup_test.rb`
proves the guard fires by calling `load` on the file after the engine is up, and
that is only safe while nothing starts SimpleCov before the raise.

**2. Pin the outcome, not only the wiring.** Two of the tests in
`test/coverage_setup_test.rb` assert that `bin/rails` and `test_helper.rb` require
the bootstrap early enough. Those catch a deleted require. They do not catch a
narrowed `cover` glob or a dead `skip` pattern, because that is a different file.
So a third test asserts **which files the configuration would actually measure**:

```ruby
assert measured.call("lib/current_scope/resolver.rb"),
       "lib/ must be measured; this is the regression the bootstrap exists to prevent"
assert_not measured.call("lib/current_scope/version.rb"),
           "version.rb loads before coverage starts and can only ever report 0%"
```

That test reaches into `SimpleCov.cover_filters` and `SimpleCov.filters`, which
are internals, on purpose: there is no public API that answers "what would this
configuration measure" without running a whole suite. One assertion guards the
two internals it reaches into:

```ruby
assert SimpleCov.respond_to?(:cover_filters) && SimpleCov.respond_to?(:filters),
       "SimpleCov's filter API moved; re-derive this pin, do not drop it"
```

Be exact about what that buys. It fails when SimpleCov renames or drops those
two methods, and it tells you to re-derive rather than delete. It cannot see a
version, and an upgrade that keeps both names while changing filter semantics
walks straight through it. The measured-set assertions above are the real signal;
this one only stops them from passing vacuously.

**3. Build the assertion from the source, never from a second copy.** The test
that checks which commands arm the bootstrap extracts the regex out of `bin/rails`
rather than restating it:

```ruby
literal = source[%r{ARGV\.first&\.match\?\(/(.+?)/\)}, 1]
```

A hand-written second copy would keep passing while the real gate narrowed
underneath it, which is the same silent drift the whole bootstrap exists to stop.

## Why This Matters

**A coverage floor inherits this bug.** #146 (PR #173) armed
`minimum_coverage line: 95, branch: 80` in CI. That gate is only as trustworthy as
the measurement under it. Trap 1 makes it fail on a healthy suite; trap 2, through
the `cover`-as-Regexp variant, makes it pass on a sick one. Neither shows up as a
tooling error.

**Trap 2 is not specific to this repo.** Any Ruby project that writes a SimpleCov
filter can hit it, and the leading-slash habit comes straight from writing
absolute paths everywhere else.

**A measurement can be real and still support a false conclusion.** The
`version.rb` filter was dropped during #145 on the strength of an A/B test, and
the comment recording that decision shipped at `fbe26005`: *"verified by A/B-ing
the skip: identical output, 1501/1545 either way."* The output was identical
because the pattern being A/B-ed was itself dead. The number was measured
honestly, and it answered a question nobody had asked.

> This entry found a live instance of that while it was being written. Both
> coverage files said SimpleCov was "pinned 1.0.2". The `Gemfile` carries
> `gem "simplecov", require: false` with no version constraint at all, and
> `Gemfile.lock` resolves 1.1.1. The comment asserted both a version and a pin,
> and was wrong about each. Corrected in the same change as this document. Read
> the lockfile, not the comment.

## When to Apply

- **Always, when adding SimpleCov to a gem or engine with a dummy app.** The
  dummy app boot is what loads your library before your bootstrap runs. A plain
  application does not have this problem in the same shape.
- **Always, when writing or editing any SimpleCov path pattern.** `skip`,
  `cover`, `group`, and their deprecated aliases `add_filter` and `add_group`.
  Anchor a Regexp with `\A`, and add or extend an outcome pin so a dead pattern
  fails something.
- **Whenever a coverage percentage moves and no test changed.** A jump in either
  direction is a measurement change, not a quality change, until proven otherwise.
- **When reviewing a filter that leads with a slash.** It may work. Check whether
  it works because the segment is mid-path, and whether the pattern beside it does.

## Examples

### Example 1: the load-order fix (#145)

*Before:* the bootstrap ran from `test/test_helper.rb`, after the dummy app and
the engine were loaded. Reported 34.95%, real 97.40%.

*After:* `bin/rails` requires it above `require "rails/engine/commands"`,
`test_helper.rb` requires it for direct runners, and the file itself refuses to
run late.

*The pin that keeps it there* (`test/coverage_setup_test.rb`), which compares
positions in the source rather than trusting that both lines exist:

```ruby
require_line = source.index(/^require_relative ["']\.\.\/test\/coverage_setup["']/)
engine_line  = source.index(/^require ["']rails\/engine\/commands["']/)

assert require_line < engine_line,
       "the coverage bootstrap must be required BEFORE rails/engine/commands; " \
       "Ruby's Coverage cannot instrument an already-loaded file"
```

Both regexes are line-anchored with `^`, because both strings also appear in the
explanatory comment above them and matching the comment would compare the wrong
positions.

### Example 2: the dead filter (#145)

*Before* (`test/coverage_setup.rb` at `fbe26005`, readable with
`git show fbe26005:test/coverage_setup.rb`):

```ruby
cover "{app,lib}/**/*.rb"
skip %r{/test/}
skip %r{/dummy/}
skip %r{/generators/.*/templates/}
```

Three Regexp filters in one style, every one of them leading with a slash. Run
against real `project_filename` values, two of them work and one does nothing:

- `%r{/dummy/}` matches `test/dummy/config/environment.rb`
- `%r{/generators/.*/templates/}` matches `lib/generators/.../templates/initializer.rb`
- `%r{/test/}` matches **nothing**, because `test/` sits at position 0

Nobody noticed, and the reason is worth keeping: `cover "{app,lib}/**/*.rb"` had
already excluded everything under `test/`, so the dead filter and the live one
produced exactly the same report. A filter that is both dead and redundant leaves
no trace at all.

*After:*

```ruby
skip %r{\Alib/generators/.*/templates/}
skip %r{\Alib/current_scope/version\.rb\z}
```

Both anchored, neither leading with a slash. The comment above them in
`test/coverage_setup.rb` now names the trap in place, so the next person editing
that block reads the rule before they write the pattern.

*The pin,* which is what makes a future dead pattern fail rather than pass:

```ruby
assert_not measured.call("lib/current_scope/version.rb"),
           "version.rb loads before coverage starts and can only ever report 0%"
```

Note what each exclusion means, because they are not the same kind. Generator
templates are host-app code, copied out and executed somewhere else, so they are
genuinely out of scope. `version.rb` is shipped runtime code that the tool cannot
see: `require "bundler/setup"` evaluates the gemspec, which `require_relative`s
it, so it is always loaded before any bootstrap could start. If real logic is ever
added to `version.rb`, it will not be measured.
