<!--
  Markdown twin of the marketing landing page. No YAML front matter: Jekyll
  must copy this as a static file. A front matter block would make it a page
  and could replace the hand-authored index.html.
-->

# CurrentScope

Authorization as data you edit in a UI, not rules you hardcode and redeploy.
Permissions come from your routes. A role is a row of ticked cells. One ambient
`allowed_to?` answers the same question in controllers, views, and components.

**Website:** <https://davidteren.github.io/current_scope/>
**Install:** `bundle add current_scope`

Beta. Built for experimentation and report-mode pilots while remaining security
items are hardened. The last gate to 1.0 is one real host on
`config.enforcement = :report`, then `:enforce`
([#116](https://github.com/davidteren/current_scope/issues/116)).

## What you get

- Permissions auto-derived from every `controller#action` pair
- Roles as editable rows on a controller × action grid
- Per-record scoped roles
- An opt-in separation-of-duties veto (initiator can never approve their own record)
- Fail-closed resolution: no grant means denied
- One ambient context via `CurrentAttributes`

## Resolver order

```
1. SoD veto        → initiator? (opt-in, off by default)  DENY (overrides all)
2. full_access     → role grants everything, forever     ALLOW
3. org-wide role   → role's permission set includes it   ALLOW
4. scoped role     → a role held on THIS record, or an   ALLOW
                     ancestor role that ticks the key
                     (opt-in; not scoped full_access)
5. record-less     → no record: a scoped grant of the     ALLOW
                     named type opens a listed collection read
6. otherwise       → default deny
```

## Docs

Machine index: [llms.txt](llms.txt). One-file ingest: [llms-full.txt](llms-full.txt).
Every HTML page has a Markdown twin at the same path with a `.md` suffix.

- [Is it the right fit?](comparison.md)
- [Quickstart](quickstart.md)
- [Adopting in an existing app](adopting-in-an-existing-app.md)
- [Concepts](concepts.md)
- [Checking permissions](checking-permissions.md)
- [Separation of duties](separation-of-duties.md)
- [Security & production checklist](security-checklist.md)
- [Configuration](configuration.md)
- [Impersonation](impersonation.md)
- [Testing](testing.md)
- [Upgrading](upgrading.md)
- [For AI agents](ai-agents.md)
- [Limitations](limitations.md)

## Source

- [GitHub](https://github.com/davidteren/current_scope)
- [RubyGems](https://rubygems.org/gems/current_scope)
- [Showcase app](https://github.com/davidteren/current_scope_showcase)
