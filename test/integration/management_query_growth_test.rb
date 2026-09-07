require "test_helper"

class ManagementQueryGrowthTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(name: "Query administrator")
    @role = CurrentScope::Role.create!(name: "Query role", permission_keys: [ "reports#index" ])
    @original_authorizer = CurrentScope.config.management_authorizer
    @assign_targets = []
    CurrentScope.config.management_authorizer = ->(subject, action:, role: nil, target: nil) do
      @assign_targets << target.id if action == :assign_role
      subject == @admin && (!role || (!role.full_access? && (role.permission_keys - [ "reports#index" ]).empty?))
    end
  end

  teardown { CurrentScope.config.management_authorizer = @original_authorizer }

  test "proposed role selects do not grow with bulk recipient count" do
    single = [ User.create!(name: "Single recipient") ]
    batch = 5.times.map { |index| User.create!(name: "Batch recipient #{index}") }
    small_count = role_selects_for_assignment(single)
    large_count = role_selects_for_assignment(batch)

    assert_operator small_count, :>, 0
    assert_equal small_count, large_count, "the proposed role should be fetched once per bulk request"
    assert_equal 6, CurrentScope::RoleAssignment.where(role: @role).count
    (single + batch).each do |recipient|
      assert_equal 2, @assign_targets.count(recipient.id), "authorize every recipient before writes and again during its write"
    end
  end

  test "existing recipients use one fresh prior role and bundle read per policy phase" do
    previous = CurrentScope::Role.create!(name: "Previous query role", permission_keys: [ "reports#index" ])
    single = [ User.create!(name: "Existing single recipient") ]
    batch = 5.times.map { |index| User.create!(name: "Existing batch recipient #{index}") }
    (single + batch).each { |recipient| CurrentScope::RoleAssignment.create!(subject: recipient, role: previous) }

    small_count = role_selects_for_assignment(single)
    large_count = role_selects_for_assignment(batch)

    # Each extra recipient needs fresh role and bundle reads in both phases.
    # A separate association fetch followed by lock! adds redundant role reads.
    assert_operator small_count, :>, 0
    assert_operator large_count - small_count, :<=, 4 * (batch.size - single.size)
    assert_equal 6, CurrentScope::RoleAssignment.where(role: @role).count
    (single + batch).each do |recipient|
      assert_equal 2, @assign_targets.count(recipient.id)
    end
  end

  test "permission reads on the roles list do not grow with role count" do
    small_count = permission_selects_for_index
    5.times do |index|
      CurrentScope::Role.create!(name: "Additional role #{index}", permission_keys: [ "reports#index" ])
    end
    large_count = permission_selects_for_index

    assert_operator small_count, :>, 0
    assert_equal small_count, large_count, "the permission bundles should be preloaded for all rendered roles"
    assert_select "#cs_edit_role_#{@role.id}"
    assert_select "#cs_delete_role_#{@role.id}:not([disabled])"
  end

  test "reusing the proposed role preserves the last full access holder" do
    owner_role = CurrentScope::Role.create!(name: "Owner", full_access: true)
    assignment = CurrentScope::RoleAssignment.create!(subject: @admin, role: owner_role)
    CurrentScope.config.management_authorizer = nil

    [ owner_role.id, @role.id, "" ].each do |proposed_id|
      post current_scope.role_assignments_url,
        params: { subject_gid: @admin.to_gid.to_s, role_id: proposed_id },
        headers: { "X-User-Id" => @admin.id.to_s }
      assert_response :redirect
      assert_equal owner_role.id, assignment.reload.role_id
      if proposed_id == owner_role.id
        assert_equal "No org-wide role changes.", flash[:notice]
      else
        assert_match(/Refusing to remove the last full-access/, flash[:alert])
      end
    end
  end

  private

  def role_selects_for_assignment(recipients)
    count_selects("current_scope_roles|current_scope_role_permissions") do
      post current_scope.role_assignments_url,
        params: { subject_gids: recipients.map { |recipient| recipient.to_gid.to_s }, role_id: @role.id },
        headers: { "X-User-Id" => @admin.id.to_s }
      assert_response :redirect
    end
  end

  def permission_selects_for_index
    count_selects("current_scope_role_permissions") do
      get current_scope.roles_url, headers: { "X-User-Id" => @admin.id.to_s }
      assert_response :success
    end
  end

  def count_selects(table)
    count = 0
    subscriber = ->(_name, _start, _finish, _id, payload) do
      sql = payload[:sql]
      count += 1 if sql.match?(/\ASELECT/i) && sql.match?(/FROM ["`]?(?:#{table})["`]?\b/i)
    end
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
    count
  end
end
