# Portable role definitions

Carry role names, descriptions, `full_access`, and permission-key bundles
between environments as one YAML document. Assignments (who holds which role,
on which record) are not in this document. That is issue #156 v2.

## Document

Identity is the role `name`. Roles are sorted by name. Keys are sorted inside
each role. `apiVersion` must be `current_scope/definitions-v1`.

```yaml
apiVersion: current_scope/definitions-v1
roles:
- name: Editor
  description: Edits reports
  full_access: false
  permission_keys:
  - reports#index
  - reports#show
- name: Owner
  description: ""
  full_access: true
  permission_keys: []
```

`full_access` must be `true` or `false`. There is no permissive cast, because a
typo in an authorization document must not grant full access. Unknown catalog
keys fail apply. Apply does not scrub. A YAML anchor, an alias, or a tagged
value is refused: the document is plain data.

## Commands

```bash
bin/rails current_scope:definitions:export FILE=config/current_scope/roles.yml
bin/rails current_scope:definitions:diff FILE=config/current_scope/roles.yml
bin/rails current_scope:definitions:import FILE=config/current_scope/roles.yml CONFIRM=1 ACTOR_ID=1
bin/rails current_scope:definitions:rollback SNAPSHOT=config/current_scope/roles.yml.pre.yml CONFIRM=1 ACTOR_ID=1
```

Import writes the pre-apply snapshot to `FILE.pre.yml`. Rollback reads
`SNAPSHOT=`, never `FILE=`. Passing the live document to rollback is a no-op.

## Confirm gate

- Production always needs `CONFIRM=1` (or `confirm: true` on the API), even
  when the roles table is empty.
- Any other environment needs confirm once any role row exists.
- A TTY prompt is allowed only when stdin is a TTY and `CI` is unset.
  Non-interactive callers pass the flag.

## Locks

Apply refuses a document that would leave zero org-wide full-access holders.
It also refuses to delete a role that still has org-wide or scoped holders.
An unassigned spare full-access role may be removed when another held
full-access role remains.

## API

```ruby
CurrentScope.export_definitions
CurrentScope.diff_definitions(yaml_or_path)
CurrentScope.import_definitions(yaml_or_path, confirm: true, actor: user)
CurrentScope.rollback_definitions(snapshot_path, confirm: true, actor: user)
```

Both take an optional `snapshot_path:`, the path the undo file is written TO.
Without it the undo file goes to `tmp/current_scope/last_definitions_snapshot.yml`.

When the document was read from a file and the undo file would land on that same
file, the undo file goes to `<document>.pre.yml` instead. That is what makes a
rollback from `tmp/current_scope/last_definitions_snapshot.yml` safe: the
snapshot survives, so a second rollback is a no-op instead of re-applying the
change. An apply that does not commit puts the undo file back the way it was.

Rake tasks are thin wrappers. `ACTOR_ID=` looks up `config.subject_class` by
primary key, the same shape as `current_scope:grant` with `SUBJECT_ID=`.
