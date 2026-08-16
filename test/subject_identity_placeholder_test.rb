require "test_helper"

class SubjectIdentityPlaceholderTest < ActiveSupport::TestCase
  MARK = CurrentScope::SubjectIdentity::PLACEHOLDER_MARK

  setup do
    @original_identity = CurrentScope.config.subject_identity
    @original_class = CurrentScope.config.subject_class
    CurrentScope.config.subject_class = "IdentityUser"
    CurrentScope.config.subject_identity = :email
  end

  teardown do
    CurrentScope.config.subject_identity = @original_identity
    CurrentScope.config.subject_class = @original_class
  end

  def factory
    lambda do |key|
      IdentityUser.create!(
        email: key,
        name: "#{MARK} #{key}"
      )
    end
  end

  def with_rails_env(name)
    original = Rails.env
    Rails.env = name
    yield
  ensure
    Rails.env = original
  end

  test "non-production plus a factory creates one marked row that later resolve finds" do
    key = "placeholder-#{SecureRandom.hex(4)}@example.com"
    before = IdentityUser.count

    record = CurrentScope::SubjectIdentity.materialize_placeholder!(key, factory: factory)

    assert_equal before + 1, IdentityUser.count
    assert_includes record.name, MARK
    assert_equal key, record.email
    assert_equal record, CurrentScope.resolve_subject(key)
  end

  test "production plus the flag raises and the count is unchanged" do
    key = "prod-#{SecureRandom.hex(4)}@example.com"
    before = IdentityUser.count

    with_rails_env("production") do
      error = assert_raises(CurrentScope::ConfigurationError) do
        CurrentScope::SubjectIdentity.materialize_placeholder!(key, factory: factory)
      end
      assert_match "refused in production", error.message
    end

    assert_equal before, IdentityUser.count
    assert_nil CurrentScope.resolve_subject(key)
  end

  test "resolve alone never inserts" do
    before = IdentityUser.count
    assert_nil CurrentScope.resolve_subject("ghost-#{SecureRandom.hex(4)}@example.com")
    assert_equal before, IdentityUser.count
  end

  test "materialize is a no-op when resolve already finds the row" do
    existing = IdentityUser.create!(name: "Real Ada", email: "real-ada@example.com")
    before = IdentityUser.count

    found = CurrentScope::SubjectIdentity.materialize_placeholder!(
      "real-ada@example.com", factory: factory
    )

    assert_equal existing, found
    assert_equal before, IdentityUser.count
  end

  test "a missing factory raises naming the mark" do
    error = assert_raises(CurrentScope::ConfigurationError) do
      CurrentScope::SubjectIdentity.materialize_placeholder!(
        "nofactory@example.com", factory: nil
      )
    end
    assert_match MARK, error.message
    assert_match "create_placeholder!", error.message
  end
end
