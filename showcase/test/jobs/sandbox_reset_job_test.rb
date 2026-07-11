require "test_helper"

class SandboxResetJobTest < ActiveJob::TestCase
  # Plant the canonical dataset the job is meant to defend, then vandalize it and
  # assert the job heals it back. (Fixtures load too, but the job treats their
  # records as visitor junk and clears them — these tests never rely on them.)
  setup { Showcase::Seeds.plant! }

  test "restores a mutated seeded role's permission grid to seed state" do
    member_role = CurrentScope::Role.find_by!(name: "Member")
    canonical = member_role.permission_keys.sort

    member_role.update!(permission_keys: %w[reports#index]) # vandalism
    assert_not_equal canonical, member_role.reload.permission_keys.sort

    SandboxResetJob.new.perform

    assert_equal canonical, member_role.reload.permission_keys.sort
  end

  test "reverts a visitor-approved seeded pay run back to pending" do
    run = PayRun.find_by!(label: "July salaries")
    approver = User.find_by!(email_address: "payroll.approver@example.com")
    run.approve!(by: approver)
    assert run.reload.approved?

    SandboxResetJob.new.perform

    run = PayRun.find_by!(label: "July salaries")
    assert_not run.approved?
    assert_equal "pending", run.status
    assert_nil run.approved_by
  end

  test "recreates a visitor-DELETED seeded record and re-points its scoped grant" do
    grant = CurrentScope::ScopedRoleAssignment.find_by!(resource: PayRun.find_by!(label: "July salaries"))
    PayRun.find_by!(label: "July salaries").destroy! # a visitor acting as Owner deletes a prop

    SandboxResetJob.new.perform

    recreated = PayRun.find_by!(label: "July salaries")
    assert CurrentScope::ScopedRoleAssignment.exists?(subject: grant.subject, role: grant.role, resource: recreated),
      "scoped grant should be re-pointed at the recreated record"
  end

  test "deletes a visitor-created domain record but keeps the seeded ones" do
    preparer = User.find_by!(email_address: "payroll.preparer@example.com")
    junk = PayRun.create!(label: "Vandal run", period: "2026-01", amount: 1, prepared_by: preparer)

    SandboxResetJob.new.perform

    assert_nil PayRun.find_by(id: junk.id)
    assert PayRun.exists?(label: "July salaries")
  end

  # The killer case: a visitor (acting as Owner) created a Role AND assigned it
  # to a user. A naive "delete roles" would hit the RESTRICT FK on the
  # assignment; the job clears grants first, so this is clean.
  test "removes a visitor-created role that is assigned to a user, no InvalidForeignKey" do
    member = User.find_by!(email_address: "member@example.com")
    rogue = CurrentScope::Role.create!(name: "Rogue")
    rogue.update!(permission_keys: %w[reports#index])
    CurrentScope::RoleAssignment.where(subject: member).delete_all
    assignment = CurrentScope::RoleAssignment.create!(subject: member, role: rogue)

    assert_nothing_raised { SandboxResetJob.new.perform }

    assert_nil CurrentScope::Role.find_by(id: rogue.id)
    assert_nil CurrentScope::RoleAssignment.find_by(id: assignment.id)
  end

  test "keeps seeded user ids stable across a reset" do
    owner_id = User.find_by!(email_address: "owner@example.com").id

    SandboxResetJob.new.perform

    assert_equal owner_id, User.find_by!(email_address: "owner@example.com").id
  end

  test "clears the append-only events ledger" do
    gid = User.find_by!(email_address: "owner@example.com").to_gid.to_s
    CurrentScope::Event.create!(event: "role.created", actor: gid, subject: gid, target: gid, target_label: "Owner")
    assert CurrentScope::Event.count.positive?

    SandboxResetJob.new.perform

    assert_equal 0, CurrentScope::Event.count
  end

  test "prunes stale visitor sessions but keeps recent ones" do
    visitor = User.visitor
    stale = visitor.sessions.create!
    stale.update_column(:created_at, 4.hours.ago) # backdate past the TTL
    fresh = visitor.sessions.create!

    SandboxResetJob.new.perform

    assert_nil Session.find_by(id: stale.id)
    assert Session.exists?(id: fresh.id)
  end

  test "runs in one transaction: a mid-run failure leaves no partial wipe" do
    preparer = User.find_by!(email_address: "payroll.preparer@example.com")
    junk = PayRun.create!(label: "Vandal run", period: "2026-01", amount: 1, prepared_by: preparer)

    # A job whose LAST step blows up: everything before it (the deletes, the
    # replant) must roll back with the transaction.
    boom_job = Class.new(SandboxResetJob) do
      private def prune_stale_sessions = raise("boom")
    end

    assert_raises(RuntimeError) { boom_job.new.perform }

    # The junk record the job had already deleted is back — nothing committed.
    assert PayRun.exists?(id: junk.id)
  end

  test "config/recurring.yml registers sandbox_reset on a 15-minute schedule" do
    config = YAML.load_file(Rails.root.join("config/recurring.yml"))
    task = config.dig("production", "sandbox_reset")

    assert_equal "SandboxResetJob", task["class"]
    assert_equal "every 15 minutes", task["schedule"]
  end
end
