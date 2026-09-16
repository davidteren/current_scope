require "test_helper"
require "rake"

# #30 — current_scope:grant warns when it replaces a non-Owner org role.
class GrantTaskTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(name: "Bootstrap")
    Rake::Task.clear
    Rake::TaskManager.record_task_metadata = true
    load Rails.root.join("../../lib/tasks/current_scope_tasks.rake").expand_path
    Rake::Task.define_task(:environment)
  end

  teardown do
    Rake::Task.clear
    ENV.delete("SUBJECT_ID")
  end

  def run_grant
    Rake::Task["current_scope:grant"].reenable
    capture_io { Rake::Task["current_scope:grant"].invoke }
  end

  test "warns when replacing a different org role" do
    member = CurrentScope::Role.create!(name: "Member")
    CurrentScope::RoleAssignment.create!(subject: @user, role: member)
    ENV["SUBJECT_ID"] = @user.id.to_s

    _out, err = run_grant
    assert_match(/WARNING/, err)
    assert_match(/Member/, err)
    assert_match(/Owner/, err)
    assert_equal "Owner", CurrentScope::RoleAssignment.find_by(subject: @user).role.name
  end

  test "no warning when the subject has no prior role" do
    ENV["SUBJECT_ID"] = @user.id.to_s

    _out, err = run_grant
    assert_no_match(/WARNING/, err)
    assert CurrentScope::RoleAssignment.find_by(subject: @user)
  end

  test "no warning on idempotent Owner re-grant" do
    CurrentScope.grant!(@user)
    ENV["SUBJECT_ID"] = @user.id.to_s

    _out, err = run_grant
    assert_no_match(/WARNING/, err)
  end

  test "does not claim full access when the existing Owner role is not full_access" do
    CurrentScope::Role.create!(name: "Owner", full_access: false)
    ENV["SUBJECT_ID"] = @user.id.to_s

    out, err = run_grant
    assert_no_match(/WARNING/, err)
    assert_no_match(/Granted the full-access/, out)
    assert_match(/does not have full access/, out)
    role = CurrentScope::RoleAssignment.find_by(subject: @user).role
    assert_equal "Owner", role.name
    assert_not role.full_access?
  end
end
