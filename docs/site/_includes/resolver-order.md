```
1. SoD veto        → initiator? (opt-in, off by default)  DENY (overrides all)
2. full_access     → role grants everything, forever      ALLOW
3. org-wide role   → role's permission set includes it    ALLOW
4. scoped role     → a role held on THIS record           ALLOW
5. otherwise       → default deny
```

One nuance the diagram folds into step 4: a **record-less** check (a
collection action like `index`) can be opened by a scoped grant too — listed
read actions derive their answer from the scoped list (`scope_for`). The
[README's record-less rules](https://github.com/davidteren/current_scope/blob/main/README.md#scoping-a-list-scope_for)
are the full treatment.
