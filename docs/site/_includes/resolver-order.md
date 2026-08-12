```
1. SoD veto        → initiator? (opt-in, off by default)  DENY (overrides all)
2. full_access     → role grants everything, forever      ALLOW
3. org-wide role   → role's permission set includes it    ALLOW
4. scoped role     → a role held on THIS record, or on    ALLOW
                     a declared parent (opt-in)
5. record-less     → no record: a scoped grant of the      ALLOW
                     named type opens a listed
                     collection read (index by default)
6. otherwise       → default deny
```

Step 4 also matches a grant on a declared parent when the child opted in
with `current_scope_parent`. Step 5 is why a scoped-only subject can reach
an index. A collection action names the type with `current_scope_model`.
The class form `allowed_to?(:index, Report)` names the type itself.
Listed reads take their answer from `scope_for` and open only when that
list is not empty, including rows reached through a declared parent.
Other record-less keys (for example `create`) need an explicit tick on
the named type; a scoped `full_access` grant does not open those. The
[record-less rules](https://github.com/davidteren/current_scope/blob/main/docs/guides/checking-permissions.md#scoping-a-list-scope_for)
are the full treatment.
