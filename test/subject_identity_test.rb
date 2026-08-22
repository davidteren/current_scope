require "test_helper"

class SubjectIdentityTest < ActiveSupport::TestCase
  setup do
    @original_identity = CurrentScope.config.subject_identity
    @original_class = CurrentScope.config.subject_class
  end

  teardown do
    CurrentScope.config.subject_identity = @original_identity
    CurrentScope.config.subject_class = @original_class
  end

  def with_database_task(answer)
    guard = CurrentScope::SchemaGuard
    original = guard.method(:running_a_database_task?)
    guard.define_singleton_method(:running_a_database_task?) { answer }
    yield
  ensure
    guard.define_singleton_method(:running_a_database_task?, original)
    guard.singleton_class.send(:public, :running_a_database_task?)
  end

  test "unset config identify/resolve match User.find(id)" do
    user = User.create!(name: "Ada")

    assert_nil CurrentScope.config.subject_identity
    assert_equal user.id.to_s, CurrentScope.identify_subject(user)
    assert_equal user, CurrentScope.resolve_subject(user.id)
    assert_equal user, CurrentScope.resolve_subject(user.id.to_s)
  end

  test "primary-key resolve refuses an array key" do
    error = assert_raises(CurrentScope::ConfigurationError) do
      CurrentScope.resolve_subject([ 1, 2 ])
    end
    assert_match "one value", error.message
  end

  test "a PK-only install still grants by id" do
    user = User.create!(name: "Owner candidate")
    CurrentScope.grant!(user)

    assert_equal "Owner", CurrentScope::RoleAssignment.find_by(subject: user).role.name
    assert_equal user, CurrentScope.resolve_subject(user.id.to_s)
  end

  test ":name on unique names round-trips" do
    user = User.create!(name: "unique-identity-ada")
    CurrentScope.config.subject_identity = :name

    assert_equal "unique-identity-ada", CurrentScope.identify_subject(user)
    assert_equal user, CurrentScope.resolve_subject("unique-identity-ada")
    assert_nothing_raised { CurrentScope.config.validate! }
  end

  test ":name with a duplicate raises at validate!" do
    User.create!(name: "dup-identity")
    User.create!(name: "dup-identity")
    CurrentScope.config.subject_identity = :name

    error = assert_raises(CurrentScope::ConfigurationError) { CurrentScope.config.validate! }
    assert_match "not unique", error.message
    assert_match "dup-identity", error.message
  end

  test "a String identity raises at assignment and the previous value stands" do
    CurrentScope.config.subject_identity = :name
    error = assert_raises(CurrentScope::ConfigurationError) do
      CurrentScope.config.subject_identity = "email"
    end
    assert_match ":email", error.message
    assert_equal :name, CurrentScope.config.subject_identity
  end

  test "a Proc identity raises at assignment and the previous value stands" do
    error = assert_raises(CurrentScope::ConfigurationError) do
      CurrentScope.config.subject_identity = ->(u) { u.name }
    end
    assert_match "Proc", error.message
    assert_match "subject_label", error.message
    assert_nil CurrentScope.config.subject_identity
  end

  test "validate during a simulated db task does not query uniqueness" do
    User.create!(name: "dup-db-task")
    User.create!(name: "dup-db-task")
    CurrentScope.config.subject_identity = :name

    with_database_task(true) do
      assert_nothing_raised { CurrentScope.config.validate! }
    end
  end

  test "[:name, :email] round-trips one IdentityUser" do
    CurrentScope.config.subject_class = "IdentityUser"
    user = IdentityUser.create!(name: "Ada", email: "ada@example.com")
    CurrentScope.config.subject_identity = [ :name, :email ]

    assert_equal [ "Ada", "ada@example.com" ], CurrentScope.identify_subject(user)
    assert_equal user, CurrentScope.resolve_subject([ "Ada", "ada@example.com" ])
    assert_nothing_raised { CurrentScope.config.validate! }
  end

  test "a composite value that contains a comma still round-trips" do
    CurrentScope.config.subject_class = "IdentityUser"
    user = IdentityUser.create!(name: "Lovelace, Ada", email: "ada@example.com")
    CurrentScope.config.subject_identity = [ :name, :email ]

    key = CurrentScope.identify_subject(user)
    assert_equal [ "Lovelace, Ada", "ada@example.com" ], key
    assert_equal user, CurrentScope.resolve_subject(key)
  end

  test "two rows with the same composite raise at validate and at resolve" do
    CurrentScope.config.subject_class = "IdentityUser"
    IdentityUser.create!(name: "Ada", email: "shared@example.com")
    IdentityUser.create!(name: "Ada", email: "shared@example.com")
    CurrentScope.config.subject_identity = [ :name, :email ]

    error = assert_raises(CurrentScope::ConfigurationError) { CurrentScope.config.validate! }
    assert_match "not unique", error.message

    resolve_error = assert_raises(CurrentScope::ConfigurationError) do
      CurrentScope.resolve_subject([ "Ada", "shared@example.com" ])
    end
    assert_match "more than one", resolve_error.message
  end

  test "two rows with blank emails do not collide and resolve of a blank key is nil" do
    CurrentScope.config.subject_class = "IdentityUser"
    IdentityUser.create!(name: "Blank One", email: nil)
    IdentityUser.create!(name: "Blank Two", email: "")
    CurrentScope.config.subject_identity = :email

    assert_nothing_raised { CurrentScope.config.validate! }
    assert_nil CurrentScope.resolve_subject("")
    assert_nil CurrentScope.resolve_subject(nil)
  end

  test "a host object identify/resolve is used as-is" do
    user = User.create!(name: "hosted-ada")
    resolver = Object.new
    resolver.define_singleton_method(:identify) { |subject| "host:#{subject.name}" }
    resolver.define_singleton_method(:resolve) { |key| User.find_by(name: key.delete_prefix("host:")) }

    CurrentScope.config.subject_identity = resolver

    assert_equal "host:hosted-ada", CurrentScope.identify_subject(user)
    assert_equal user, CurrentScope.resolve_subject("host:hosted-ada")
  end

  test "a host object without unique? does not invent a scan at validate!" do
    resolver = Object.new
    resolver.define_singleton_method(:identify) { |_subject| "x" }
    resolver.define_singleton_method(:resolve) { |_key| nil }

    CurrentScope.config.subject_identity = resolver
    assert_nothing_raised { CurrentScope.config.validate! }
  end

  test "a wrong-shaped composite key raises rather than looking missing" do
    CurrentScope.config.subject_class = "IdentityUser"
    CurrentScope.config.subject_identity = [ :name, :email ]

    error = assert_raises(CurrentScope::ConfigurationError) do
      CurrentScope.resolve_subject("only-one-part")
    end
    assert_match "expected 2 value", error.message
  end

  test "resolve alone never inserts" do
    before = User.count
    CurrentScope.config.subject_identity = :name

    assert_nil CurrentScope.resolve_subject("nobody-#{SecureRandom.hex(4)}")
    assert_equal before, User.count
  end

  test "an empty array raises at assignment" do
    assert_raises(CurrentScope::ConfigurationError) do
      CurrentScope.config.subject_identity = []
    end
    assert_nil CurrentScope.config.subject_identity
  end

  test "a missing column raises at validate!" do
    CurrentScope.config.subject_identity = :email

    error = assert_raises(CurrentScope::ConfigurationError) { CurrentScope.config.validate! }
    assert_match ":email", error.message
    assert_match "no such column", error.message
  end

  # identify used to stringify nil to "", producing a key that resolve treats
  # as no key at all. An export would have carried that dead key forward.
  test "identify refuses a blank identity column instead of minting a dead key" do
    CurrentScope.config.subject_class = "IdentityUser"
    user = IdentityUser.create!(name: "Blank Email", email: nil)
    CurrentScope.config.subject_identity = :email

    error = assert_raises(CurrentScope::ConfigurationError) { CurrentScope.identify_subject(user) }
    assert_match ":email", error.message
    assert_match "blank", error.message
    assert_nil CurrentScope.resolve_subject("")
  end

  test "identify names every blank part of a composite" do
    CurrentScope.config.subject_class = "IdentityUser"
    user = IdentityUser.create!(name: "   ", email: "")
    CurrentScope.config.subject_identity = [ :name, :email ]

    error = assert_raises(CurrentScope::ConfigurationError) { CurrentScope.identify_subject(user) }
    assert_match ":name", error.message
    assert_match ":email", error.message
  end

  test "whitespace-only values are not a collision, because neither resolves" do
    CurrentScope.config.subject_class = "IdentityUser"
    IdentityUser.create!(name: "Space One", email: "   ")
    IdentityUser.create!(name: "Space Two", email: "   ")
    CurrentScope.config.subject_identity = :email

    assert_nothing_raised { CurrentScope.config.validate! }
    assert_nil CurrentScope.resolve_subject("   ")
  end

  def grouping_queries
    seen = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      seen << payload[:sql] if payload[:sql].to_s.match?(/GROUP BY/i)
    end
    yield
    seen
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # The boot error tells hosts to add a unique index. Honour it, or that advice
  # costs them a full table grouping on every boot forever after.
  test "a unique index answers the boot check with no grouping query at all" do
    CurrentScope.config.subject_class = "IdentityUser"
    IdentityUser.create!(name: "Token Ada", token: "tok-#{SecureRandom.hex(4)}")
    CurrentScope.config.subject_identity = :token

    queries = grouping_queries { assert_nothing_raised { CurrentScope.config.validate! } }

    assert_empty queries, "a unique index on the identity column already proves this"
  end

  test "without an index the boot check runs one grouping query, not one per column" do
    CurrentScope.config.subject_class = "IdentityUser"
    IdentityUser.create!(name: "Probe Ada", email: "probe-#{SecureRandom.hex(4)}@example.com")
    CurrentScope.config.subject_identity = [ :name, :email ]

    queries = grouping_queries { assert_nothing_raised { CurrentScope.config.validate! } }

    assert_equal 1, queries.size, "one grouping query for the whole composite"
  end

  # SQL TRIM() removes spaces and nothing else; Ruby's String#strip also
  # removes tabs and newlines. Ruby therefore has the final say, or boot would
  # refuse to start over a duplicate that resolve treats as no key at all.
  test "tab-only and newline-only values are not a collision on any adapter" do
    CurrentScope.config.subject_class = "IdentityUser"
    IdentityUser.create!(name: "Tab One", email: "\t")
    IdentityUser.create!(name: "Tab Two", email: "\t")
    IdentityUser.create!(name: "Newline One", email: "\n")
    IdentityUser.create!(name: "Newline Two", email: "\n")
    CurrentScope.config.subject_identity = :email

    assert_nothing_raised { CurrentScope.config.validate! }
    assert_empty CurrentScope.config.subject_identity_resolver.colliding_keys
    assert_nil CurrentScope.resolve_subject("\t")
  end

  test "a real duplicate is still found when blank rows share the table" do
    CurrentScope.config.subject_class = "IdentityUser"
    IdentityUser.create!(name: "Blank", email: "\t")
    IdentityUser.create!(name: "Blank Too", email: "\t")
    shared = "real-dupe-#{SecureRandom.hex(4)}@example.com"
    IdentityUser.create!(name: "Real One", email: shared)
    IdentityUser.create!(name: "Real Two", email: shared)
    CurrentScope.config.subject_identity = :email

    error = assert_raises(CurrentScope::ConfigurationError) { CurrentScope.config.validate! }
    assert_match "not unique", error.message
    assert_match shared, error.message
  end
end
