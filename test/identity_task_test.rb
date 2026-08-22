require "test_helper"
require "rake"
require "stringio"

class IdentityTaskTest < ActiveSupport::TestCase
  MARK = CurrentScope::SubjectIdentity::PLACEHOLDER_MARK

  setup do
    @original_identity = CurrentScope.config.subject_identity
    @original_class = CurrentScope.config.subject_class
    @stdout = StringIO.new
  end

  teardown do
    CurrentScope.config.subject_identity = @original_identity
    CurrentScope.config.subject_class = @original_class
    %w[IDENTITY SUBJECT ROLE WRITE PLACEHOLDER].each { |key| ENV.delete(key) }
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

  test "dry-run names the user and writes nothing" do
    user = User.create!(name: "dry-run-ada")

    assert_no_difference -> { CurrentScope::RoleAssignment.count } do
      out = run_setup("IDENTITY" => "name", "SUBJECT" => "dry-run-ada")
      assert_match "dry-run-ada", out
      assert_match "Would grant Owner", out
      assert_match "WRITE=1", out
    end

    assert_nil CurrentScope::RoleAssignment.find_by(subject: user)
  end

  test "dry-run does not seed Owner or create a named role" do
    User.create!(name: "dry-role-ada")
    CurrentScope::Role.where(name: %w[Owner Member DryAdmin]).delete_all

    assert_no_difference -> { CurrentScope::Role.count } do
      out = run_setup(
        "IDENTITY" => "name",
        "SUBJECT" => "dry-role-ada",
        "ROLE" => "DryAdmin"
      )
      assert_match "Would grant DryAdmin", out
    end

    assert_not CurrentScope::Role.exists?(name: "DryAdmin")
    assert_not CurrentScope::Role.exists?(name: "Owner")
  end

  test "dry-run PLACEHOLDER without a factory does not pretend it can create" do
    before = User.count
    error = assert_raises(CurrentScope::IdentitySetup::Halt) do
      run_setup(
        "IDENTITY" => "name",
        "SUBJECT" => "ghost-dry",
        "PLACEHOLDER" => "1"
      )
    end

    assert_equal before, User.count
    assert_match "no factory", error.message
    assert_match MARK, error.message
  end

  test "dry-run PLACEHOLDER with a factory writes nothing" do
    factory = Object.new
    factory.define_singleton_method(:identify) { |subject| subject.name }
    factory.define_singleton_method(:resolve) { |key| User.find_by(name: key) }
    factory.define_singleton_method(:unique?) { true }
    factory.define_singleton_method(:create_placeholder!) do |key|
      User.create!(name: key)
    end
    CurrentScope.config.subject_identity = factory

    before = User.count
    out = run_setup("SUBJECT" => "ghost-dry-host", "PLACEHOLDER" => "1")

    assert_equal before, User.count
    assert_match "Would create a placeholder", out
    assert_match MARK, out
  end

  test "IDENTITY= does not rewrite CurrentScope.config" do
    User.create!(name: "cfg-ada")
    assert_nil CurrentScope.config.subject_identity

    run_setup("IDENTITY" => "name", "SUBJECT" => "cfg-ada")

    assert_nil CurrentScope.config.subject_identity
  end

  test "replacing an existing org role warns on dry-run" do
    user = User.create!(name: "swap-ada")
    member = CurrentScope::Role.create!(name: "Member")
    CurrentScope::RoleAssignment.create!(subject: user, role: member)

    _out, err = capture_io do
      run_setup("IDENTITY" => "name", "SUBJECT" => "swap-ada")
    end
    assert_match(/WARNING/, err)
    assert_match(/Member/, err)
    assert_equal "Member", CurrentScope::RoleAssignment.find_by(subject: user).role.name
  end

  test "WRITE grants Owner through grant! and records a bootstrap event" do
    user = User.create!(name: "write-ada")

    out = run_setup("IDENTITY" => "name", "SUBJECT" => "write-ada", "WRITE" => "1")

    assignment = CurrentScope::RoleAssignment.find_by(subject: user)
    assert_equal "Owner", assignment.role.name
    assert assignment.role.full_access?
    assert_match "Granted Owner", out

    event = CurrentScope::Event.where(event: "org_role.assigned").order(:id).last
    assert_equal "bootstrap", event.details["source"]
    assert_equal "Owner", event.details["role"]
  end

  test "uniqueness collision aborts before grant" do
    User.create!(name: "collide-ada")
    User.create!(name: "collide-ada")

    error = assert_raises(CurrentScope::IdentitySetup::Halt) do
      run_setup("IDENTITY" => "name", "SUBJECT" => "collide-ada", "WRITE" => "1")
    end
    assert_match "not unique", error.message
    assert_equal 0, CurrentScope::RoleAssignment.count
  end

  test "production placeholder aborts and creates no row" do
    before = User.count

    with_rails_env("production") do
      error = assert_raises(CurrentScope::IdentitySetup::Halt) do
        run_setup(
          "IDENTITY" => "name",
          "SUBJECT" => "ghost-prod",
          "PLACEHOLDER" => "1"
        )
      end
      assert_match "refused in production", error.message
    end

    assert_equal before, User.count
  end

  test "default Admin is not full_access" do
    User.create!(name: "admin-ada")

    run_setup(
      "IDENTITY" => "name",
      "SUBJECT" => "admin-ada",
      "ROLE" => "Admin",
      "WRITE" => "1"
    )

    role = CurrentScope::Role.find_by!(name: "Admin")
    assert_not role.full_access?
  end

  test "missing subject without PLACEHOLDER aborts" do
    error = assert_raises(CurrentScope::IdentitySetup::Halt) do
      run_setup("IDENTITY" => "name", "SUBJECT" => "missing-ada")
    end
    assert_match "No subject resolved", error.message
  end

  test "the agent prompt names only shipped setup flags" do
    prompt = File.read(File.expand_path("../docs/site/ai-agents.md", __dir__))
    %w[IDENTITY= SUBJECT= ROLE= WRITE=1 PLACEHOLDER=1].each do |flag|
      assert_match flag, prompt
    end
    assert_match "never invent a production subject", prompt
  end

  # identity:check runs in CI, in cron, and in deploy hooks. A blocking
  # $stdin.gets there is not a question, it is a hang.
  test "collisions and unique? never prompt, even on a tty" do
    User.create!(name: "quiet-ada")
    tty = StringIO.new
    tty.define_singleton_method(:tty?) { true }
    tty.define_singleton_method(:gets) { raise "identity:check must not prompt" }
    setup = CurrentScope::IdentitySetup.new(env: {}, stdout: @stdout, stdin: tty)

    assert setup.unique?
    assert_empty setup.collisions
    assert_equal "", @stdout.string
  end

  # A host resolver may know it has a duplicate and be unable to name one.
  # That used to be printed as the colliding key "(duplicate natural key)",
  # which reads as a natural key somebody actually stored.
  test "an unlistable duplicate is reported as unlistable, not as a fake key" do
    resolver = Object.new
    resolver.define_singleton_method(:identify) { |_subject| "x" }
    resolver.define_singleton_method(:resolve) { |_key| nil }
    resolver.define_singleton_method(:unique?) { false }
    CurrentScope.config.subject_identity = resolver
    setup = CurrentScope::IdentitySetup.new(env: {}, stdout: @stdout, stdin: StringIO.new)

    assert_not setup.unique?
    assert_empty setup.collisions

    error = assert_raises(CurrentScope::IdentitySetup::Halt) do
      run_setup("SUBJECT" => "anyone")
    end
    assert_match "does not list the colliding keys", error.message
    assert_no_match(/duplicate natural key/, error.message)
  end

  test "an exported but empty ROLE falls back to Owner" do
    user = User.create!(name: "empty-role-ada")

    run_setup("IDENTITY" => "name", "SUBJECT" => "empty-role-ada", "ROLE" => "", "WRITE" => "1")

    assert_equal "Owner", CurrentScope::RoleAssignment.find_by(subject: user).role.name
    assert_not CurrentScope::Role.exists?(name: "")
  end

  test "a composite SUBJECT with the wrong number of values says so" do
    CurrentScope.config.subject_class = "IdentityUser"
    CurrentScope.config.subject_identity = [ :name, :email ]

    error = assert_raises(CurrentScope::IdentitySetup::Halt) do
      run_setup("SUBJECT" => "[Ada]")
    end
    assert_match "gave 1 value", error.message
    assert_match ":email", error.message
  ensure
    CurrentScope.config.subject_class = "User"
  end

  # safe_load PARSES this and then refuses to build the Date, raising
  # Psych::DisallowedClass — which is not a Psych::SyntaxError.
  test "a composite SUBJECT YAML refuses to build halts instead of raising Psych" do
    CurrentScope.config.subject_class = "IdentityUser"
    CurrentScope.config.subject_identity = [ :name, :email ]

    error = assert_raises(CurrentScope::IdentitySetup::Halt) do
      run_setup("SUBJECT" => "[2026-01-01, ada@example.com]")
    end
    assert_match "YAML sequence", error.message
  ensure
    CurrentScope.config.subject_class = "User"
  end

  test "a composite SUBJECT with a blank part is refused" do
    CurrentScope.config.subject_class = "IdentityUser"
    CurrentScope.config.subject_identity = [ :name, :email ]

    error = assert_raises(CurrentScope::IdentitySetup::Halt) do
      run_setup("SUBJECT" => "[Ada, '  ']")
    end
    assert_match "blank part", error.message
  ensure
    CurrentScope.config.subject_class = "User"
  end

  test "the rake task dry-run writes nothing" do
    User.create!(name: "rake-ada")
    Rake::Task.clear
    load Rails.root.join("../../lib/tasks/current_scope_tasks.rake").expand_path
    Rake::Task.define_task(:environment)

    ENV["IDENTITY"] = "name"
    ENV["SUBJECT"] = "rake-ada"
    Rake::Task["current_scope:identity:setup"].reenable

    assert_no_difference -> { CurrentScope::RoleAssignment.count } do
      capture_io { Rake::Task["current_scope:identity:setup"].invoke }
    end
  ensure
    Rake::Task.clear
  end
end
