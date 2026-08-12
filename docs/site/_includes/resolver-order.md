```
1. SoD veto        → initiator? (opt-in, off by default)  DENY (overrides all)
2. full_access     → role grants everything, forever      ALLOW
3. org-wide role   → role's permission set includes it    ALLOW
4. scoped role     → a role held on THIS record           ALLOW
5. record-less     → no record: a scoped grant of the      ALLOW
                     declared type opens a listed
                     collection read (index by default)
6. otherwise       → default deny
```

Step 5 is why a scoped-only subject can reach an index. Listed reads take
their answer from `scope_for`. The
[record-less rules](https://github.com/davidteren/current_scope/blob/main/docs/guides/checking-permissions.md#scoping-a-list-scope_for)
are the full treatment.
