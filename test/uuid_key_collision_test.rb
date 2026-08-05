require "test_helper"

# #151. `subject_id` and `resource_id` used to be integer columns, so a UUID
# primary key was cast by String#to_i on write: "7f00aaaa-…" and "7f00bbbb-…"
# both stored as 7. Two subjects became one identity and one inherited the
# other's roles, `full_access` included.
#
# The columns are string now, so both shapes store whole and a UUID-keyed host is
# SUPPORTED rather than refused. These tests assert that support, and pin the
# column type so a narrowing migration could never pass quietly.
class UuidKeyCollisionTest < ActiveSupport::TestCase
  ALICE_ID = "7f00aaaa-1111-4111-8111-aaaaaaaaaaaa".freeze
  BOB_ID   = "7f00bbbb-2222-4222-8222-bbbbbbbbbbbb".freeze

  # Built ONCE, at load time, before any test transaction opens. Two reasons:
  # MySQL cannot run DDL inside a transaction — it auto-commits and the test's
  # savepoint vanishes underneath it — and ActiveRecord's schema API is used
  # rather than raw SQL because `id varchar PRIMARY KEY` is valid SQLite and a
  # syntax error on MySQL. The suite runs on all three adapters (bin/db).
  ActiveRecord::Base.connection.create_table(:uuid_users, id: :string, force: true) do |t|
    t.string :name
  end
  UuidUser = Class.new(ActiveRecord::Base) do
    self.table_name = "uuid_users"
    def self.name = "UuidUser"
  end
  Object.const_set(:UuidUser, UuidUser) unless Object.const_defined?(:UuidUser)

  # Drop the table and the constant when the whole run ends, not per test: any
  # later test that inspects ActiveRecord::Base.descendants or the table list
  # would otherwise be order-dependent on this file having run.
  Minitest.after_run do
    ActiveRecord::Base.connection.drop_table(:uuid_users, if_exists: true)
    Object.send(:remove_const, :UuidUser) if Object.const_defined?(:UuidUser)
  rescue StandardError
    nil
  end

  setup do
    @alice = UuidUser.create!(id: ALICE_ID, name: "Alice")
    @bob   = UuidUser.create!(id: BOB_ID, name: "Bob")
    @resolver = CurrentScope::Resolver.new
  end

  # Rows only: the transaction rolls these back anyway, but the table itself must
  # survive the run (see above).
  teardown { UuidUser.delete_all }

  test "the id columns hold a value, not a number — this is what makes UUIDs work" do
    %w[current_scope_role_assignments current_scope_scoped_role_assignments].each do |table|
      column = ActiveRecord::Base.connection.columns(table).find { |c| c.name == "subject_id" }
      assert_equal :string, column.type,
                   "#{table}.subject_id must stay a string column; narrowing it back to " \
                   "integer would truncate every UUID and re-open #151"
    end
  end

  test "a UUID-keyed subject holds an org-wide role, and only that subject holds it" do
    role = CurrentScope::Role.create!(name: "Owner", full_access: true)
    CurrentScope::RoleAssignment.create!(subject: @alice, role: role)

    assert @resolver.full_access?(@alice), "the granted subject holds it"
    assert_not @resolver.full_access?(@bob),
               "and the OTHER subject does not — this is the escalation #151 described, " \
               "closed by storing the whole key rather than its leading digits"
  end

  test "the whole UUID is stored, not its leading digits" do
    role = CurrentScope::Role.create!(name: "Owner", full_access: true)
    grant = CurrentScope::RoleAssignment.create!(subject: @alice, role: role)

    assert_equal ALICE_ID, grant.reload.subject_id
    assert_equal ALICE_ID.to_i, BOB_ID.to_i,
                 "both UUIDs still cast to the same integer — the reason the column type matters"
  end

  test "a scoped grant on a UUID-keyed resource reaches only that record" do
    role = CurrentScope::Role.create!(name: "Editor")
    role.role_permissions.create!(permission_key: "uuid_users#show")
    holder = User.create!(name: "Holder")
    CurrentScope::ScopedRoleAssignment.create!(subject: holder, role: role, resource: @alice)

    assert_equal [ true, nil ],
                 @resolver.decide(subject: holder, permission: "uuid_users#show", record: @alice)
    assert_equal [ false, :no_grant ],
                 @resolver.decide(subject: holder, permission: "uuid_users#show", record: @bob),
                 "the grant names one record, not every record whose key starts the same way"
  end

  test "integer-keyed subjects are unaffected" do
    role = CurrentScope::Role.create!(name: "Owner", full_access: true)
    user = User.create!(name: "Normal")
    CurrentScope::RoleAssignment.create!(subject: user, role: role)

    assert @resolver.full_access?(user)
    assert_not @resolver.full_access?(User.create!(name: "Other"))
  end

  test "a mixed host works: integer and UUID subjects side by side" do
    integer_user = User.create!(name: "Integer User")
    CurrentScope::RoleAssignment.create!(
      subject: integer_user, role: CurrentScope::Role.create!(name: "Owner", full_access: true)
    )
    CurrentScope::RoleAssignment.create!(
      subject: @alice, role: CurrentScope::Role.create!(name: "Owner2", full_access: true)
    )

    assert @resolver.full_access?(integer_user)
    assert @resolver.full_access?(@alice)
    assert_not @resolver.full_access?(@bob)
  end

  test "a key that is not ONE value is still refused — it names no single record" do
    composite = Class.new(ActiveRecord::Base) do
      self.table_name = "reports"
      self.primary_key = [ "id", "project_id" ]
      def self.name = "CompositeReport"
    end
    keyless = Class.new(ActiveRecord::Base) do
      self.table_name = "reports"
      self.primary_key = nil
      def self.name = "KeylessReport"
    end

    assert_not CurrentScope.storable_key?(composite)
    assert_not CurrentScope.storable_key?(keyless)
    assert CurrentScope.storable_key?(UuidUser), "a UUID key is ONE value, so it is fine"
    assert CurrentScope.storable_key?(User)

    assert_match(/composite primary key/, CurrentScope.unstorable_key_error(composite))
    assert_match(/no primary key/, CurrentScope.unstorable_key_error(keyless))
  end

  test "a key too long for the column is refused, not truncated" do
    long = "x" * (CurrentScope::KEY_LIMIT + 1)
    holder = UuidUser.create!(id: long[0, CurrentScope::KEY_LIMIT], name: "Fits")
    role = CurrentScope::Role.create!(name: "Owner", full_access: true)

    grant = CurrentScope::RoleAssignment.new(role: role)
    grant.subject_type = "UuidUser"
    grant.subject_id = long

    assert_not grant.valid?,
               "MySQL outside strict mode truncates silently, so two keys sharing a " \
               "#{CurrentScope::KEY_LIMIT}-character prefix would collapse into one identity"
    assert_match(/characters/, grant.errors.full_messages.to_sentence)
    assert CurrentScope::RoleAssignment.new(subject: holder, role: role).valid?,
           "and a key that fits is unaffected"
  end

  test "the engine refuses to boot if the widening migration has not run" do
    # A gem upgrade does not run migrations. Without this check a host would keep
    # integer columns, keep the escalation, and see nothing wrong.
    assert_nothing_raised { CurrentScope::Engine.validate_subject_key! }

    # Present the pre-migration schema by overriding the reader the check uses.
    # A plain singleton method rather than a mocking library, which this suite
    # does not carry.
    fake = { "subject_id" => Struct.new(:type).new(:integer) }
    CurrentScope::RoleAssignment.define_singleton_method(:columns_hash) { fake }
    begin
      error = assert_raises(CurrentScope::ConfigurationError) do
        CurrentScope::Engine.validate_subject_key!
      end
      assert_match(/still integer/, error.message)
      assert_match(/db:migrate/, error.message, "the message must name the fix")
    ensure
      CurrentScope::RoleAssignment.singleton_class.send(:remove_method, :columns_hash)
    end
  end

  test "the boot check does not refuse a UUID subject class" do
    original = CurrentScope.config.subject_class
    CurrentScope.config.subject_class = "UuidUser"

    assert_nothing_raised { CurrentScope::Engine.validate_subject_key! }
  ensure
    CurrentScope.config.subject_class = original
  end

  test "the boot check stays silent when it cannot introspect" do
    original = CurrentScope.config.subject_class
    CurrentScope.config.subject_class = "NoSuchSubjectModel"

    assert_nothing_raised { CurrentScope::Engine.validate_subject_key! }
  ensure
    CurrentScope.config.subject_class = original
  end
end
