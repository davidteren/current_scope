# #151. `subject_id` and `resource_id` were integer columns, so a host whose
# models use UUID (or any non-numeric) primary keys had those ids cast by
# String#to_i on write: "7f00aaaa-…" and "7f00bbbb-…" both stored as 7. Two
# subjects became one identity and one inherited the other's roles.
#
# Widening to string supports BOTH shapes with no configuration to get wrong: an
# integer key stores as "1", a UUID stores whole. Equality is the only comparison
# these columns ever see (the resolver never orders or ranges on them), so string
# storage costs nothing but index width.
#
# COLLATION IS FORCED BINARY ON MYSQL. Its default (utf8mb4_0900_ai_ci) is case
# AND accent insensitive, so "ABC" and "abc" — or "jose" and "josé" — compare
# equal. A grant to one would then match the other, which is #151 all over again
# with a different mechanism. A record's primary key is an identifier, not prose;
# it must compare byte for byte. PostgreSQL and SQLite already do.
#
# LENGTH IS BOUNDED AT 64 ON PURPOSE. These columns sit in a five-column unique
# index, and MySQL caps an index at 3072 bytes; four unbounded varchar(255)
# columns at utf8mb4 exceed that and the table will not create at all. 64 holds a
# UUID (36), a ULID (26), and any integer key with room to spare.
#
# THIS MIGRATION CANNOT REPAIR ALREADY-COLLAPSED ROWS. Once "7f00aaaa-…" was
# written as 7 the original value is gone. A host that ran 0.2 to 0.4 with
# non-integer keys must re-grant those roles; UPGRADING.md carries the audit
# query that lists them.
# Bracketed [7.1] like every other migration this engine ships. The bracket pins
# generation-time schema defaults, not the gem's minimum Rails, and the three
# existing migrations all use it — a mechanical bump to match the Rails floor is
# exactly what this repo's readiness plan says not to do.
class WidenCurrentScopePolymorphicIds < ActiveRecord::Migration[7.1]
  KEY_LIMIT = 64
  # utf8mb4_bin is binary but PAD SPACE, so it still compares "abc" equal to
  # "abc " — a trailing space would make two keys one identity, the same
  # escalation the case-folding fix closed. utf8mb4_0900_bin is binary AND NO
  # PAD (MySQL 8.0.17+). Prefer it; fall back where the server is older, since a
  # case-sensitive comparison is still far better than the ai_ci default.
  PREFERRED_COLLATION = "utf8mb4_0900_bin".freeze
  FALLBACK_COLLATION = "utf8mb4_bin".freeze

  COLUMNS = {
    current_scope_role_assignments: [ :subject_id ],
    current_scope_scoped_role_assignments: [ :subject_id, :resource_id ]
  }.freeze

  # The TYPE columns pair with the id in every grant predicate and in the unique
  # index, so folding them is the same escalation by another column: on MySQL's
  # default collation a grant on `Foo#5` would match a check for `FOO#5`. They are
  # already varchar; only the collation changes, and only on MySQL.
  TYPE_COLUMNS = {
    current_scope_role_assignments: [ :subject_type ],
    current_scope_scoped_role_assignments: [ :subject_type, :resource_type ]
  }.freeze

  def up
    COLUMNS.each do |table, columns|
      columns.each { |column| widen(table, column) }
    end
    return unless mysql?

    TYPE_COLUMNS.each do |table, columns|
      columns.each { |column| binary_collate(table, column) }
    end
  end

  # Deliberately irreversible. Going back to integer would silently truncate
  # every UUID it now holds — the exact data loss this migration exists to stop.
  def down
    raise ActiveRecord::IrreversibleMigration,
          "Narrowing subject_id/resource_id back to integer would truncate any " \
          "non-integer key stored since the upgrade (#151). Restore from a backup " \
          "if you need the previous schema."
  end

  private

  def mysql? = connection.adapter_name.match?(/mysql|trilogy|maria/i)

  # Asked once per run, not per column: it is a catalog query.
  def binary_collation
    @binary_collation ||=
      if connection.select_value(
        "SELECT 1 FROM information_schema.collations " \
        "WHERE collation_name = #{connection.quote(PREFERRED_COLLATION)}"
      )
        PREFERRED_COLLATION
      else
        FALLBACK_COLLATION
      end
  end

  def already_correct?(table, column)
    existing = connection.columns(table).find { |c| c.name == column.to_s }
    return false if existing.nil?
    return false unless existing.type == :string && existing.limit == KEY_LIMIT

    !mysql? || existing.collation == binary_collation
  end

  # Collation only — the type columns are already the right type and width.
  def binary_collate(table, column)
    existing = connection.columns(table).find { |c| c.name == column.to_s }
    return if existing.nil? || existing.collation == binary_collation

    change_column table, column, :string, limit: existing.limit,
                  null: false, collation: binary_collation
  end

  def widen(table, column)
    # Idempotent, but NOT satisfied by type and width alone: a database built from
    # schema.rb already has varchar(64) while carrying the server's default
    # collation, which on MySQL is case-insensitive. Skipping there would leave the
    # #151 collision live on every freshly-loaded schema.
    return if already_correct?(table, column)

    if connection.adapter_name.match?(/postg/i)
      # Postgres will not cast integer to varchar implicitly in ALTER COLUMN; it
      # needs USING. change_column does not emit one, so write it directly.
      connection.execute(<<~SQL.squish)
        ALTER TABLE #{connection.quote_table_name(table)}
        ALTER COLUMN #{connection.quote_column_name(column)} TYPE character varying(#{KEY_LIMIT})
        USING #{connection.quote_column_name(column)}::character varying
      SQL
    elsif mysql?
      change_column table, column, :string, limit: KEY_LIMIT,
                    null: false, collation: binary_collation
      return
    else
      # SQLite rebuilds the table and compares BINARY by default.
      change_column table, column, :string, limit: KEY_LIMIT
    end

    change_column_null table, column, false
  end
end
