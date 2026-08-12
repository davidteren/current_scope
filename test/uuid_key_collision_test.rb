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

  # UuidUser and its table live in test/support/uuid_user.rb — shared with the
  # management-UI test that drives roles#members with a UUID-keyed subject_class.

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

  # The RESOURCE side of the same guard. Without this, dropping "resource" from
  # validates_storable_polymorphic_keys would break nothing in the suite.
  test "an over-long resource id is refused too, and the message names the right side" do
    role = CurrentScope::Role.create!(name: "Editor")
    holder = User.create!(name: "Holder")

    grant = CurrentScope::ScopedRoleAssignment.new(role: role, subject: holder)
    grant.resource_type = "UuidUser"
    grant.resource_id = "x" * (CurrentScope::KEY_LIMIT + 1)

    assert_not grant.valid?
    message = grant.errors.full_messages.to_sentence
    assert_match(/resource id is #{CurrentScope::KEY_LIMIT + 1} characters/, message)
    assert_no_match(/subject id is/, message,
                    "the subject side fits — naming it would send the reader to the wrong column")
  end

  # The write side of the read-side collapse below: the column takes any string,
  # so nothing about storing a UUID against a bigint-keyed model looks wrong at
  # write time. It is wrong, and this is where it gets refused.
  test "an id that is not a legal key for its own model is refused" do
    role = CurrentScope::Role.create!(name: "Editor")
    role.role_permissions.create!(permission_key: "projects#show")
    holder = User.create!(name: "Holder")

    grant = CurrentScope::ScopedRoleAssignment.new(role: role, subject: holder)
    grant.resource_type = "Project"
    grant.resource_id = ALICE_ID

    assert_not grant.valid?,
               "Project keys on a bigint, so this UUID would be cast back to 7 and the " \
               "grant would open Project 7 — a record it never named (#151)"
    assert_match(/not a valid Project primary key/, grant.errors.full_messages.to_sentence)

    assert CurrentScope.canonical_key?(User, "7"), "a canonical integer key round-trips"
    assert_not CurrentScope.canonical_key?(User, "007"),
               "\"007\" casts to 7, so it would name a record it does not spell"
    assert_not CurrentScope.canonical_key?(User, (2**63).to_s),
               "a value outside bigint's range must be refused before a database query raises"
    assert_not CurrentScope.canonical_key?(User, ""),
               "a blank id names no record and must never be canonical"
    assert_not CurrentScope.canonical_key?(UuidUser, ""),
               "blank is non-canonical for a string key too"
    assert CurrentScope.canonical_key?(UuidUser, ALICE_ID), "a UUID is canonical for a string key"
  end

  test "a loaded model with a custom polymorphic token still gets key validation" do
    original = UuidUser.method(:polymorphic_name)
    UuidUser.define_singleton_method(:polymorphic_name) { "uuid_people" }

    assert_equal UuidUser, CurrentScope.polymorphic_class("uuid_people")

    role = CurrentScope::Role.create!(name: "Editor")
    grant = CurrentScope::RoleAssignment.new(role: role)
    grant.subject_type = "uuid_people"
    grant.subject_id = "x" * (CurrentScope::KEY_LIMIT + 1)
    grant.send(:current_scope_check_storable_keys, [ "subject" ])
    assert grant.errors.any?, "a custom storage token must not bypass the key guard"
  ensure
    UuidUser.define_singleton_method(:polymorphic_name, original)
  end

  # The read side. A row written before this guard existed — or by host code that
  # grants straight from params — is already in the table, so the resolver cannot
  # trust what it reads. This is the test that would have caught the escalation
  # moving from the write path to the read path.
  test "a stored id that names no record grants nothing, and the gate agrees with the list" do
    role = CurrentScope::Role.create!(name: "Editor")
    role.role_permissions.create!(permission_key: "projects#index")
    role.role_permissions.create!(permission_key: "projects#show")
    holder = User.create!(name: "Holder")
    seven = Project.create!(name: "Seven")

    # Straight past the validation, the way a legacy row got there.
    connection = ActiveRecord::Base.connection
    connection.execute(<<~SQL.squish)
      INSERT INTO current_scope_scoped_role_assignments
        (role_id, subject_type, subject_id, resource_type, resource_id, created_at, updated_at)
      VALUES (#{role.id}, 'User', #{connection.quote(holder.id.to_s)}, 'Project',
              #{connection.quote("#{seven.id}f00aaaa-1111-4111-8111-aaaaaaaaaaaa")},
              #{connection.quote(Time.current)}, #{connection.quote(Time.current)})
    SQL

    assert_empty @resolver.scope_for(subject: holder, model: Project, permission: "projects#index").to_a,
                 "String#to_i would turn that id into #{seven.id} and list a project the grant never named"
    assert_equal [ false, :no_grant ],
                 @resolver.decide(subject: holder, permission: "projects#index", record: nil, model: Project),
                 "the collection gate asks scope_for, so it must deny for the same reason"
    assert_equal [ false, :no_grant ],
                 @resolver.decide(subject: holder, permission: "projects#show", record: seven),
                 "and the per-record gate must not disagree with the list"
  end

  test "the engine refuses to boot if the widening migration has not run" do
    # A gem upgrade does not run migrations. Without this check a host would keep
    # integer columns, keep the escalation, and see nothing wrong.
    assert_nothing_raised { CurrentScope::SchemaGuard.check! }

    # Present the pre-migration schema by overriding the reader the check uses.
    # A plain singleton method rather than a mocking library, which this suite
    # does not carry.
    fake = { "subject_id" => Struct.new(:type).new(:integer) }
    CurrentScope::RoleAssignment.define_singleton_method(:columns_hash) { fake }
    begin
      error = assert_raises(CurrentScope::ConfigurationError) do
        CurrentScope::SchemaGuard.check!
      end
      assert_match(/still integer/, error.message)
      assert_match(/db:migrate/, error.message, "the message must name the fix")
    ensure
      CurrentScope::RoleAssignment.singleton_class.send(:remove_method, :columns_hash)
    end
  end

  # The migration widens the id columns and THEN re-collates the type columns,
  # and MySQL auto-commits each statement — so a migration that dies between the
  # two leaves binary ids beside case-insensitive types, permanently. A check
  # that reads only the id columns blesses exactly that state, and a grant on
  # `Widget#5` then matches a check for `WIDGET#5`.
  test "the boot check refuses a half-applied MySQL schema, not just an unmigrated one" do
    column = Struct.new(:type, :limit, :collation)
    half_applied = {
      "subject_id" => column.new(:string, CurrentScope::KEY_LIMIT, "utf8mb4_0900_bin"),
      "subject_type" => column.new(:string, nil, "utf8mb4_0900_ai_ci")
    }
    CurrentScope::RoleAssignment.define_singleton_method(:columns_hash) { half_applied }
    with_mysql(true) do
      error = assert_raises(CurrentScope::ConfigurationError) do
        CurrentScope::SchemaGuard.check!
      end
      assert_match(/subject_type/, error.message,
                   "the id columns are already correct — the TYPE column is what is still folding case")
      assert_match(/utf8mb4_0900_ai_ci/, error.message)
    ensure
      CurrentScope::RoleAssignment.singleton_class.send(:remove_method, :columns_hash)
    end
  end

  # A security guard must not fail open. If a MySQL column exists but its
  # collation cannot be read, the guard cannot prove it compares case-sensitively,
  # so it must refuse rather than bless it — matching the fatal treatment
  # roles_controller#candidate_key_as_text gives the same missing metadata.
  test "the boot check refuses a MySQL column whose collation cannot be read" do
    column = Struct.new(:type, :limit, :collation, :null)
    unreadable = { "subject_id" => column.new(:string, CurrentScope::KEY_LIMIT, nil, false) }
    CurrentScope::RoleAssignment.define_singleton_method(:columns_hash) { unreadable }
    with_mysql(true) do
      error = assert_raises(CurrentScope::ConfigurationError) do
        CurrentScope::SchemaGuard.check!
      end
      assert_match(/collation could not be read/, error.message)
      assert_match(/repair_schema/, error.message, "the message must name the fix")
    ensure
      CurrentScope::RoleAssignment.singleton_class.send(:remove_method, :columns_hash)
    end
  end

  # "Is it a string?" is not the whole question. A varchar(32) answers yes and
  # then truncates every UUID written to it — the original collision, reached by
  # a column that passed the guard meant to prevent it.
  test "the boot check refuses a string column too narrow to hold a key" do
    column = Struct.new(:type, :limit, :collation)
    narrow = { "subject_id" => column.new(:string, 32, nil) }
    CurrentScope::RoleAssignment.define_singleton_method(:columns_hash) { narrow }
    begin
      error = assert_raises(CurrentScope::ConfigurationError) do
        CurrentScope::SchemaGuard.check!
      end
      assert_match(/holds 32 characters/, error.message)
      assert_match(/repair_schema/, error.message, "the message must name the fix")
    ensure
      CurrentScope::RoleAssignment.singleton_class.send(:remove_method, :columns_hash)
    end
  end

  test "the schema guard accepts an unbounded text id column" do
    column = Struct.new(:type, :limit, :collation, :null)
    # A real MySQL text column always carries a collation; give the stub a valid
    # binary one so this exercises WIDTH acceptance (limit nil is fine) without
    # tripping the collation guard, which now fails closed on an unreadable one.
    text = { "subject_id" => column.new(:text, nil, "utf8mb4_0900_bin", false) }
    CurrentScope::RoleAssignment.define_singleton_method(:columns_hash) { text }

    assert_nothing_raised { CurrentScope::SchemaGuard.check! }
  ensure
    CurrentScope::RoleAssignment.singleton_class.send(:remove_method, :columns_hash)
  end

  test "assignment writes recheck the schema even during an exempt database task" do
    fake = { "subject_id" => Struct.new(:type).new(:integer) }
    CurrentScope::RoleAssignment.define_singleton_method(:columns_hash) { fake }
    role = CurrentScope::Role.create!(name: "Editor")
    grant = CurrentScope::RoleAssignment.new(subject: User.create!(name: "Seeded"), role: role)

    with_database_task(true) do
      assert_raises(CurrentScope::ConfigurationError) { grant.valid? }
    end
  ensure
    CurrentScope::RoleAssignment.singleton_class.send(:remove_method, :columns_hash)
  end

  test "the boot refusal stands down for database tasks, or the fix could not be run" do
    # grant_columns_widened! raises from after_initialize, which EVERY rails
    # command runs — including the db:migrate its own message tells the host to
    # run. Without the exemption an upgrading host is stuck: the app will not
    # boot and the repair will not run, for the same reason.
    fake = { "subject_id" => Struct.new(:type).new(:integer) }
    CurrentScope::RoleAssignment.define_singleton_method(:columns_hash) { fake }
    begin
      # Drive the seam in BOTH directions rather than reading the ambient Rake
      # state: other task tests in this suite leave their own top-level tasks
      # behind, which would make this assertion depend on file order.
      with_database_task(false) do
        assert_raises(CurrentScope::ConfigurationError, "serving must still be refused") do
          CurrentScope::SchemaGuard.check!
        end
      end

      with_database_task(true) do
        assert_nothing_raised { CurrentScope::SchemaGuard.check! }
      end
    ensure
      CurrentScope::RoleAssignment.singleton_class.send(:remove_method, :columns_hash)
    end
  end

  # Every other exemption test stubs running_a_database_task? itself, so the LIST
  # it consults was never exercised: deleting an entry broke no test. These drive
  # the real prefix match through Rake's own top_level_tasks.
  test "the boot exemption covers the commands that must run against an unmigrated schema" do
    {
      "db:migrate" => true,                      # the prescribed repair
      "db:test:prepare" => true,
      "app:db:migrate" => true,                  # the same, from an engine
      "current_scope:install:migrations" => true,
      "current_scope:repair_schema" => true,     # the MySQL collation repair
      "app:current_scope:repair_schema" => true,
      "assets:precompile" => true,               # a deploy that builds before migrating
      # db: is for the REPAIR path. These two repair nothing and run the host's
      # own code — seeds routinely create grants, and on the pre-migration schema
      # those are the writes that collapse two subjects into one.
      "db:schema:load" => true,
      "db:setup" => true,                        # rebuilds; refusing it strands a broken schema
      "db:reset" => true,
      "db:seed" => false,
      "db:seed:replant" => false,                # Rails ships this one; a host may add more
      "db:fixtures:load" => false,
      "app:db:seed" => false,
      "db:migrate:up" => true,                   # a real Rails child task
      # A host's OWN db:-namespaced task is host code, not schema tooling, and an
      # allow list is what keeps it from inheriting the repair path's exemption.
      "db:import_users" => false,
      "db:backfill" => false,
      # Names that START with an exempt task. Prefix matching would wave all of
      # these through, which is how an allow list quietly becomes `db:` again.
      "db:create_tenant" => false,
      "db:migrate_legacy_users" => false,
      "db:dropbears" => false,
      "db:setup_hostile" => false,
      "test" => false,                           # and everything else is still refused
      "current_scope:report" => false,
      "middleware" => false
    }.each do |task, exempt|
      with_top_level_tasks([ task ]) do
        assert_equal exempt, CurrentScope::SchemaGuard.send(:running_a_database_task?),
                     "#{task} should #{exempt ? '' : 'NOT '}be allowed to boot on an unmigrated schema"
      end
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

  # Force the "is this a database task?" answer WITHOUT touching the real Rake: an
  # earlier version removed Rake.application in its ensure and broke every test
  # that uses the actual rake tasks. The original method object is saved and put
  # back, visibility included.
  def with_database_task(answer)
    guard = CurrentScope::SchemaGuard
    original = guard.method(:running_a_database_task?)
    guard.define_singleton_method(:running_a_database_task?) { answer }
    yield
  ensure
    guard.define_singleton_method(:running_a_database_task?, original)
    guard.singleton_class.send(:private, :running_a_database_task?)
  end

  # Stand a double in for the whole Rake application, and put back whatever was
  # there before — INCLUDING nil, which is what it actually is under `bin/rails
  # test`. Mutating the real object is not an option for that reason, and an
  # earlier attempt that cleared Rake.application outright broke every test that
  # drives the real rake tasks.
  def with_top_level_tasks(tasks)
    # Under `bin/rails test` the Rake CONSTANT exists while Rake.application does
    # not — rake is only partially loaded — which is why the guard's
    # respond_to?(:application) is what actually decides there. Supply the method
    # for the duration, and put back exactly what was (or was not) there.
    double = Object.new
    double.define_singleton_method(:top_level_tasks) { tasks }
    had_application = Rake.respond_to?(:application)
    saved = Rake.method(:application) if had_application
    Rake.define_singleton_method(:application) { double }
    yield
  ensure
    if had_application
      Rake.define_singleton_method(:application, saved)
    else
      Rake.singleton_class.send(:remove_method, :application)
    end
  end

  # Same seam, for the adapter answer: the collation half of the check only runs
  # on MySQL, and the suite must pin it on every adapter rather than only when it
  # happens to be pointed at MySQL.
  def with_mysql(answer)
    guard = CurrentScope::SchemaGuard
    original = guard.method(:mysql?)
    guard.define_singleton_method(:mysql?) { answer }
    yield
  ensure
    guard.define_singleton_method(:mysql?, original)
    guard.singleton_class.send(:private, :mysql?)
  end
end
