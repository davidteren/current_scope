require "test_helper"

class SubjectLockingTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(name: "Owner")
    @recipient = User.create!(name: "Recipient")
    @role = CurrentScope::Role.create!(name: "Reviewer")
    @resource = Folder.create!(name: "Folder")
    CurrentScope::RoleAssignment.create!(subject: @owner,
      role: CurrentScope::Role.create!(name: "Owner", full_access: true))
    @original_authorizer = CurrentScope.config.management_authorizer
  end

  teardown do
    CurrentScope.config.management_authorizer = @original_authorizer
  end

  %i[org scoped].each do |scope|
    test "#{scope} grants support recipients with unsaved after_find defaults" do
      with_recipient_callback do
        post_grant(scope)

        assert_redirected_to current_scope.subjects_path
        assert assignment_scope(scope).exists?
        assert_equal "Recipient", User.where(id: @recipient.id).pick(:name),
          "granting access must not persist the host's load-time default"
      end
    end

    test "#{scope} grants authorize the fresh locked recipient rather than the located snapshot" do
      CurrentScope.config.management_authorizer = lambda do |_actor, action:, role:, target:|
        target.nil? || !target.name.start_with?("Protected")
      end
      with_recipient_callback(change_stored_name: true) do
        post_grant(scope)

        assert_response :forbidden
        assert_not assignment_scope(scope).exists?
        assert_equal "Protected", User.where(id: @recipient.id).pick(:name)
      end
    end
  end

  private

  def with_recipient_callback(change_stored_name: false)
    first_load = true
    recipient_id = @recipient.id
    callback = lambda do |record|
      next unless record.id == recipient_id

      # Change the real row after GlobalID has read it. The later lock must
      # return current data, not merely lock the old object's row.
      if first_load && change_stored_name
        User.where(id: recipient_id).update_all(name: "Protected")
      end
      first_load = false
      record.name = "#{record.name} loaded"
    end
    User.set_callback(:find, :after, callback)
    yield
  ensure
    User.skip_callback(:find, :after, callback)
  end

  def post_grant(scope)
    params = { subject_gid: @recipient.to_gid.to_s, role_id: @role.id }
    params[:resource_gid] = @resource.to_gid.to_s if scope == :scoped
    path = scope == :org ? current_scope.role_assignments_url : current_scope.scoped_role_assignments_url
    post path, params: params, headers: { "X-User-Id" => @owner.id.to_s }
  end

  def assignment_scope(scope)
    klass = scope == :org ? CurrentScope::RoleAssignment : CurrentScope::ScopedRoleAssignment
    klass.where(subject: @recipient, role: @role)
  end
end
