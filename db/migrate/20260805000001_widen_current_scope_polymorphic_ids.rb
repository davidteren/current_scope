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
# LENGTH IS BOUNDED AT 64 ON PURPOSE. These columns sit in a five-column unique
# index, and MySQL caps an index at 3072 bytes; four unbounded varchar(255)
# columns at utf8mb4 exceed that and the table will not create at all. 64 holds a
# UUID (36), a ULID (26), and any integer key with room to spare.
#
# THIS MIGRATION CANNOT REPAIR ALREADY-COLLAPSED ROWS. Once "7f00aaaa-…" was
# written as 7 the original value is gone. A host that ran 0.2 to 0.4 with
# non-integer keys must re-grant those roles; UPGRADING.md carries the audit
# query that lists them.
class WidenCurrentScopePolymorphicIds < ActiveRecord::Migration[8.1]
  KEY_LIMIT = 64

  COLUMNS = {
    current_scope_role_assignments: [ :subject_id ],
    current_scope_scoped_role_assignments: [ :subject_id, :resource_id ]
  }.freeze

  def up
    COLUMNS.each do |table, columns|
      columns.each { |column| widen(table, column) }
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

  def widen(table, column)
    return if connection.column_exists?(table, column, :string, limit: KEY_LIMIT)

    if connection.adapter_name.match?(/postg/i)
      # Postgres will not cast integer to varchar implicitly in ALTER COLUMN; it
      # needs USING. change_column does not emit one, so write it directly.
      connection.execute(<<~SQL.squish)
        ALTER TABLE #{connection.quote_table_name(table)}
        ALTER COLUMN #{connection.quote_column_name(column)} TYPE character varying(#{KEY_LIMIT})
        USING #{connection.quote_column_name(column)}::character varying
      SQL
    else
      # SQLite rebuilds the table; MySQL/MariaDB emit MODIFY COLUMN. Both cast
      # integer to text without help.
      change_column table, column, :string, limit: KEY_LIMIT
    end

    change_column_null table, column, false
  end
end
