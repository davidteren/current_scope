require "test_helper"
require "stringio"

# The placeholder path as it actually ships: through IdentitySetup, which is
# what the current_scope:identity:setup task runs. There used to be a second
# implementation, SubjectIdentity.materialize_placeholder!, that only these
# tests called — and it resolved through CurrentScope.config while the task
# resolves through its own IDENTITY= override, so the two could disagree about
# which subject a key meant. It is gone; this exercises the one that runs.
class SubjectIdentityPlaceholderTest < ActiveSupport::TestCase
  MARK = CurrentScope::SubjectIdentity::PLACEHOLDER_MARK

  setup do
    @original_identity = CurrentScope.config.subject_identity
    @original_class = CurrentScope.config.subject_class
    CurrentScope.config.subject_class = "IdentityUser"
    @stdout = StringIO.new
  end

  teardown do
    CurrentScope.config.subject_identity = @original_identity
    CurrentScope.config.subject_class = @original_class
  end

  # identify / resolve / create_placeholder! on one object, the shape
  # `bin/rails generate current_scope:identity` scaffolds.
  def identity_object(creates: :matching)
    object = Object.new
    object.define_singleton_method(:identify) { |subject| subject.email }
    object.define_singleton_method(:resolve) { |key| IdentityUser.find_by(email: key) }
    object.define_singleton_method(:unique?) { true }
    object.define_singleton_method(:create_placeholder!) do |key|
      email = creates == :matching ? key : "wrong-#{key}"
      IdentityUser.create!(email: email, name: "#{MARK} #{key}")
    end
    object
  end

  def run_setup(env)
    CurrentScope::IdentitySetup.new(env: env, stdout: @stdout, stdin: StringIO.new).run
    @stdout.string
  end

  def with_rails_env(name)
    original = Rails.env
    Rails.env = name
    yield
  ensure
    Rails.env = original
  end

  test "outside production a factory creates one marked row that resolve then finds" do
    CurrentScope.config.subject_identity = identity_object
    key = "placeholder-#{SecureRandom.hex(4)}@example.com"
    before = IdentityUser.count

    out = run_setup("SUBJECT" => key, "PLACEHOLDER" => "1", "WRITE" => "1")

    assert_equal before + 1, IdentityUser.count
    created = IdentityUser.find_by!(email: key)
    assert_includes created.name, MARK
    assert_equal created, CurrentScope.resolve_subject(key)
    assert_match "Created placeholder", out
    assert_equal "Owner", CurrentScope::RoleAssignment.find_by(subject: created).role.name
  end

  test "production plus the flag halts and the count is unchanged" do
    CurrentScope.config.subject_identity = identity_object
    key = "prod-#{SecureRandom.hex(4)}@example.com"
    before = IdentityUser.count

    with_rails_env("production") do
      error = assert_raises(CurrentScope::IdentitySetup::Halt) do
        run_setup("SUBJECT" => key, "PLACEHOLDER" => "1", "WRITE" => "1")
      end
      assert_match "refused in production", error.message
    end

    assert_equal before, IdentityUser.count
    assert_nil CurrentScope.resolve_subject(key)
  end

  test "resolve alone never inserts" do
    CurrentScope.config.subject_identity = identity_object
    before = IdentityUser.count

    assert_nil CurrentScope.resolve_subject("ghost-#{SecureRandom.hex(4)}@example.com")

    assert_equal before, IdentityUser.count
  end

  test "an already-resolvable subject is granted without creating a placeholder" do
    CurrentScope.config.subject_identity = identity_object
    existing = IdentityUser.create!(name: "Real Ada", email: "real-#{SecureRandom.hex(4)}@example.com")
    before = IdentityUser.count

    run_setup("SUBJECT" => existing.email, "PLACEHOLDER" => "1", "WRITE" => "1")

    assert_equal before, IdentityUser.count
    assert_equal "Owner", CurrentScope::RoleAssignment.find_by(subject: existing).role.name
  end

  test "a missing factory halts naming the mark and writes nothing" do
    object = Object.new
    object.define_singleton_method(:identify) { |subject| subject.email }
    object.define_singleton_method(:resolve) { |_key| nil }
    CurrentScope.config.subject_identity = object
    before = IdentityUser.count

    error = assert_raises(CurrentScope::IdentitySetup::Halt) do
      run_setup("SUBJECT" => "nofactory@example.com", "PLACEHOLDER" => "1", "WRITE" => "1")
    end

    assert_match "no factory", error.message
    assert_match MARK, error.message
    assert_equal before, IdentityUser.count
  end

  # materialize_placeholder no longer opens a transaction of its own — the
  # caller already holds one. Prove the rollback the caller's transaction gives
  # it is real: a factory that writes a row NOT carrying the requested key must
  # leave nothing behind.
  test "a factory whose row does not carry the key leaves no row behind" do
    CurrentScope.config.subject_identity = identity_object(creates: :mismatched)
    key = "mismatch-#{SecureRandom.hex(4)}@example.com"
    before = IdentityUser.count

    error = assert_raises(CurrentScope::IdentitySetup::Halt) do
      run_setup("SUBJECT" => key, "PLACEHOLDER" => "1", "WRITE" => "1")
    end

    assert_match "placeholder factory produced", error.message
    assert_equal before, IdentityUser.count
    assert_nil IdentityUser.find_by(email: "wrong-#{key}")
  end
end
