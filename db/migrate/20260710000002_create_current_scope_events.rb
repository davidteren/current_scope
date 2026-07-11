class CreateCurrentScopeEvents < ActiveRecord::Migration[7.1]
  # Append-only authorization event ledger. This migration ships to arbitrary
  # hosts and is NEVER renamed after release, so the schema shape is FROZEN.
  #
  # NORMATIVE target mapping (mirrored in the Event model header):
  #   - assignment events (org_role.*, scoped_role.*): target = the GRANTEE
  #     (the subject being granted). The role/resource ride in `details`.
  #   - role.* events: target = the role itself.
  def change
    create_table :current_scope_events do |t|
      t.string :event, null: false         # namespaced past-tense name (role.created, permission.granted, ...)
      t.string :actor, null: false         # GlobalID of the REAL actor (never nil: record! raises first)
      t.string :subject, null: false       # GlobalID of the effective subject; ALWAYS set (== actor unless impersonating)
      t.string :target, null: false        # GlobalID of the thing acted on (see normative mapping above)
      t.string :target_label, null: false  # denormalized human label so history survives target deletion
      # json (NOT jsonb): an opaque, append-only payload the engine never
      # queries, so it needs no index/operator support — and plain json is the
      # portable type across SQLite / PostgreSQL / MySQL.
      t.json :details
      t.string :request_id                 # correlation-only, not evidence (client-suppliable via X-Request-Id)
      # created_at only — declared explicitly, NOT via t.timestamps. There is
      # deliberately no updated_at: its absence documents append-only intent.
      t.datetime :created_at, null: false

      # Append-only + host-side retention => unbounded growth, so unindexed
      # scans are forever. Newest-first reads use order(id: :desc) (append-only
      # => id order == commit order), so no created_at index is needed.
      t.index :target
      t.index :actor
    end
  end
end
