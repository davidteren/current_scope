```
1. SoD veto        → initiator? (opt-in, off by default)  DENY (overrides all)
2. full_access     → role grants everything, forever      ALLOW
3. org-wide role   → role's permission set includes it    ALLOW
4. scoped role     → a role held on THIS record           ALLOW
5. otherwise       → default deny
```
