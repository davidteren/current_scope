require "test_helper"

# The load-time support tables (test/support/uuid_user.rb, identity_user.rb)
# persist between runs and are shared by every test process on one database.
# Non-transactional: this runs real DDL, which MySQL auto-commits.
class SupportTablesTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  UUID_SUPPORT = File.expand_path("support/uuid_user.rb", __dir__)

  def conn = ActiveRecord::Base.connection

  test "a support table whose columns drifted is rebuilt on load" do
    conn.add_column(UuidUser.table_name, :stale, :string)
    UuidUser.reset_column_information

    load UUID_SUPPORT
    UuidUser.reset_column_information

    assert_equal %w[id name], conn.columns(UuidUser.table_name).map(&:name).sort,
      "if_not_exists alone would have kept the stale column until db:test:prepare"
  end

  test "a support table that matches is left alone, rows included" do
    UuidUser.create!(id: "keep-me", name: "Kept")

    load UUID_SUPPORT

    assert UuidUser.exists?("keep-me"),
      "a matching table must never be dropped: another test process may be using it"
  ensure
    UuidUser.where(id: "keep-me").delete_all
  end

  # The tables persist, so a test-env db:migrate would dump them into the
  # tracked schema.rb unless the dumper is told to skip them.
  test "the support tables never reach schema.rb" do
    io = StringIO.new
    ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, io)

    assert_empty io.string.scan(/create_table "current_scope_test_\w+"/),
      "test/dummy/config/environments/test.rb must ignore the current_scope_test_ prefix"
  end
end
