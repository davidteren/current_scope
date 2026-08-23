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

Unknown catalog keys fail apply. Apply does not scrub.

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

Both take an optional `snapshot_path:`. Without it the undo file goes to
`tmp/current_scope/last_definitions_snapshot.yml`. An apply never writes that
file over the document it is applying: rolling back from a snapshot writes the
new undo file to `<snapshot>.pre.yml` instead, so the snapshot survives and a
second rollback is a no-op. An apply that fails puts the undo file back the way
it was.

Rake tasks are thin wrappers. `ACTOR_ID=` looks up `config.subject_class` by
primary key, the same shape as `current_scope:grant` with `SUBJECT_ID=`.
