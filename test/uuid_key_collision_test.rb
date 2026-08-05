require "test_helper"

# #151. `subject_id` and `resource_id` are integer columns (`t.references`), so a
# non-integer primary key is cast by String#to_i on write. Two UUIDs that share
# leading digits — or any two that start with a letter, both casting to 0 —
# become ONE identity, and a subject inherits a role nobody granted them.
#
# The escalation is reproduced first, against the raw columns, so the guards below
# are pinned to a demonstrated failure rather than a hypothesis.
class UuidKeyCollisionTest < ActiveSupport::TestCase
  ALICE_ID = "7f00aaaa-1111-4111-8111-aaaaaaaaaaaa".freeze
  BOB_ID   = "7f00bbbb-2222-4222-8222-bbbbbbbbbbbb".freeze

  setup do
    ActiveRecord::Base.connection.execute(
      "CREATE TABLE IF NOT EXISTS uuid_users (id varchar PRIMARY KEY, name varchar)"
    )
    unless Object.const_defined?(:UuidUser)
      Object.const_set(:UuidUser, Class.new(ActiveRecord::Base) do
        self.table_name = "uuid_users"
        def self.name = "UuidUser"
      end)
    end
    @alice = UuidUser.create!(id: ALICE_ID, name: "Alice")
    @bob   = UuidUser.create!(id: BOB_ID, name: "Bob")
    @resolver = CurrentScope::Resolver.new
  end

  teardown { UuidUser.delete_all }

  test "the collision is real: two distinct UUIDs cast to the same integer" do
    assert_not_equal @alice.id, @bob.id, "the records are genuinely different"
    assert_equal @alice.id.to_i, @bob.id.to_i,
                 "but the integer column stores the same value for both — this is the bug"
    assert_equal 7, @alice.id.to_i, "String#to_i takes the leading digits"
  end

  test "a UUID-keyed subject cannot be granted an org-wide role" do
    role = CurrentScope::Role.create!(name: "Owner", full_access: true)
    assignment = CurrentScope::RoleAssignment.new(subject: @alice, role: role)

    assert_not assignment.valid?, "granting on a UUID-keyed subject must be refused"
    assert_match(/collapses to its leading digits/, assignment.errors.full_messages.to_sentence)
    assert_match(/issues\/151/, assignment.errors.full_messages.to_sentence,
                 "the message must point at the tracking issue")
  end

  test "refusing the grant is what stops the escalation" do
    role = CurrentScope::Role.create!(name: "Owner", full_access: true)

    assert_raises(ActiveRecord::RecordInvalid) do
      CurrentScope::RoleAssignment.create!(subject: @alice, role: role)
    end

    # The point of the refusal: with no row written, Bob inherits nothing.
    assert_not @resolver.full_access?(@bob),
               "Bob was never granted anything and must not hold full_access"
    assert_not @resolver.full_access?(@alice), "and the refused grant did not take effect"
  end

  test "the escalation DOES happen if the guard is bypassed — this is what it prevents" do
    role = CurrentScope::Role.create!(name: "Owner", full_access: true)
    # save(validate: false) is the only way to write the row now; it reproduces
    # exactly what every version before this fix stored.
    CurrentScope::RoleAssignment.new(subject: @alice, role: role).save(validate: false)

    assert @resolver.full_access?(@bob),
           "with the bad row present, Bob inherits Alice's org-wide full_access — " \
           "the escalation #151 describes, and the reason the write is refused"
  end

  test "a scoped grant is refused on either side" do
    role = CurrentScope::Role.create!(name: "Editor")
    role.role_permissions.create!(permission_key: "reports#index")
    report = Report.create!(title: "Q3", requested_by: User.create!(name: "Req"))

    bad_subject = CurrentScope::ScopedRoleAssignment.new(subject: @alice, role: role, resource: report)
    assert_not bad_subject.valid?, "a UUID-keyed SUBJECT must be refused"
    assert_match(/UuidUser/, bad_subject.errors.full_messages.to_sentence)

    bad_resource = CurrentScope::ScopedRoleAssignment.new(
      subject: User.create!(name: "Ok"), role: role, resource: @alice
    )
    assert_not bad_resource.valid?, "a UUID-keyed RESOURCE must be refused too"
    assert_match(/resource id in an integer column/, bad_resource.errors.full_messages.to_sentence)
  end

  test "ordinary integer-keyed models are unaffected" do
    role = CurrentScope::Role.create!(name: "Owner", full_access: true)
    user = User.create!(name: "Normal")

    assert CurrentScope::RoleAssignment.new(subject: user, role: role).valid?,
           "the guard must not refuse the ordinary shape"
    assert CurrentScope.integer_keyed?(User)
    assert CurrentScope.integer_keyed?(Report)
  end

  # The gap that let the first version of this guard through review: it read the
  # ASSOCIATION, which is nil on a row whose id points at nothing — precisely the
  # rows the guard exists for. grant! then re-escalated them.
  test "an ALREADY-collapsed row cannot be re-granted" do
    role = CurrentScope::Role.create!(name: "Owner", full_access: true)
    bad = CurrentScope::RoleAssignment.new(subject: @alice, role: role)
    bad.save(validate: false)

    assert_nil bad.reload.subject, "the stored id resolves to no record — this is a collapsed row"
    assert_not bad.valid?, "and it must still be refused, not skipped for having a nil association"
    assert_match(/UuidUser/, bad.errors.full_messages.to_sentence)
  end

  test "the guard skips a stale polymorphic type rather than adding a second failure" do
    role = CurrentScope::Role.create!(name: "Owner", full_access: true)
    assignment = CurrentScope::RoleAssignment.new(role: role)
    assignment.subject_type = "NoLongerAModel"
    assignment.subject_id = 1

    # `valid?` on a stale type already raises NameError from Rails' own belongs_to
    # presence validation (polymorphic_class_for), on main and before this guard —
    # verified, not assumed. So the guard is exercised directly: it must resolve
    # the type to nil and skip, contributing no error of its own.
    assert_nothing_raised { assignment.send(:subject_key_is_integer) }
    assert_empty assignment.errors, "a type that no longer resolves is skipped, not flagged"
  end

  test "composite and absent primary keys are refused too — neither fits one integer column" do
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

    assert_not CurrentScope.integer_keyed?(composite),
               "a composite key cannot be stored in a single integer column"
    assert_not CurrentScope.integer_keyed?(keyless), "and neither can no key at all"

    assert_match(/composite primary key/, CurrentScope.non_integer_key_error(composite))
    assert_match(/no usable primary key/, CurrentScope.non_integer_key_error(keyless),
                 "the message must build for the nil branch rather than raising")
  end

  test "the boot check names the same problem as the write validation" do
    original = CurrentScope.config.subject_class
    CurrentScope.config.subject_class = "UuidUser"

    error = assert_raises(CurrentScope::ConfigurationError) do
      CurrentScope::Engine.validate_subject_key!
    end
    assert_match(/UuidUser/, error.message)
    assert_match(/issues\/151/, error.message)
  ensure
    CurrentScope.config.subject_class = original
  end

  test "the boot check refuses a STORED grant on a non-integer-keyed type" do
    # The population the write validations cannot help: rows a host already wrote
    # on 0.2 to 0.4, which keep escalating on every read. config.subject_class does
    # not see them, and a scoped grant can name any model as its resource.
    role = CurrentScope::Role.create!(name: "Owner", full_access: true)
    CurrentScope::RoleAssignment.new(subject: @alice, role: role).save(validate: false)

    error = assert_raises(CurrentScope::ConfigurationError) do
      CurrentScope::Engine.validate_subject_key!
    end
    assert_match(/holds grants on UuidUser/, error.message)
    assert_match(/issues\/151/, error.message)
  end

  test "a stored grant on an unresolvable type is skipped, not refused" do
    role = CurrentScope::Role.create!(name: "Owner", full_access: true)
    row = CurrentScope::RoleAssignment.new(subject: User.create!(name: "Ok"), role: role)
    row.save!
    row.update_columns(subject_type: "LongGoneModel")

    # That is #90's inert grant, a different problem with its own label.
    assert_nothing_raised { CurrentScope::Engine.validate_subject_key! }
  end

  test "the boot check stays silent when it cannot introspect" do
    original = CurrentScope.config.subject_class
    CurrentScope.config.subject_class = "NoSuchSubjectModel"

    # Unknown must not become broken: a boot before migrate, or a class that does
    # not resolve yet, has to pass rather than fail the deploy.
    assert_nothing_raised { CurrentScope::Engine.validate_subject_key! }
  ensure
    CurrentScope.config.subject_class = original
  end
end
