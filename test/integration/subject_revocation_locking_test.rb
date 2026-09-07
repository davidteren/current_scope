require "test_helper"
require "timeout"

class SubjectRevocationLockingTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(name: "Owner")
    @recipient = User.create!(name: "Recipient")
    @protected = User.create!(name: "Protected")
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
    test "#{scope} revocations support unsaved host load defaults" do
      assignment = create_assignment(scope)
      with_recipient_callback do
        revoke(scope, assignment)
      end
      assert_redirected_to current_scope.subjects_path
      assert_not assignment.class.exists?(assignment.id)
      assert_equal "Recipient", User.where(id: @recipient.id).pick(:name)
    end

    test "#{scope} revocations authorize fresh recipient state" do
      assignment = create_assignment(scope)
      CurrentScope.config.management_authorizer = lambda do |_actor, action:, role:, target:|
        target.nil? || target.name != "Protected"
      end
      first_load = true
      callback = lambda do |_record|
        if first_load
          User.where(id: @recipient.id).update_all(name: "Protected")
          first_load = false
        end
      end
      with_recipient_callback(callback) { revoke(scope, assignment) }
      assert_response :forbidden
      assert assignment.class.exists?(assignment.id)
    end

    test "#{scope} revocations refuse an assignment retargeted before its lock" do
      assignment = create_assignment(scope)
      first_load = true
      callback = lambda do |_record|
        if first_load
          assignment.class.where(id: assignment.id).update_all(subject_id: @protected.id.to_s)
          first_load = false
        end
      end
      with_recipient_callback(callback) { revoke(scope, assignment) }
      assert_redirected_to current_scope.subjects_path
      assert assignment.class.exists?(assignment.id)
      assert_equal @recipient.id.to_s, assignment.reload.subject_id,
        "the same-connection race simulation rolls back with the refused revocation"
      assert_match(/changed.*retry/i, flash[:alert])
    end

    test "#{scope} revocations clean up deleted and noncanonical recipients without naming another user" do
      [ "999999999", "#{@recipient.id}legacy" ].each do |stored_id|
        assignment = create_assignment(scope)
        assignment.update_columns(subject_id: stored_id)
        seen_targets = []
        CurrentScope.config.management_authorizer = lambda do |_actor, action:, role:, target:|
          seen_targets << target if action.to_s.start_with?("revoke")
          true
        end
        revoke(scope, assignment)
        assert_redirected_to current_scope.subjects_path
        assert_not assignment.class.exists?(assignment.id)
        assert_equal [ nil ], seen_targets
      end
    end
  end

  private

  def with_recipient_callback(change = ->(record) { record.name = "Unsaved default" })
    recipient_id = @recipient.id
    callback = ->(record) { change.call(record) if record.id == recipient_id }
    User.set_callback(:find, :after, callback)
    yield
  ensure
    User.skip_callback(:find, :after, callback)
  end

  def create_assignment(scope)
    attributes = { subject: @recipient, role: @role }
    attributes[:resource] = @resource if scope == :scoped
    klass = scope == :org ? CurrentScope::RoleAssignment : CurrentScope::ScopedRoleAssignment
    klass.create!(attributes)
  end

  def revoke(scope, assignment)
    path = scope == :org ? current_scope.role_assignment_url(assignment) : current_scope.scoped_role_assignment_url(assignment)
    delete path, headers: { "X-User-Id" => @owner.id.to_s }
  end
end

# Observe the first console lock and the host's role-lock attempt. A real host
# transaction changes the recipient while holding its row, then locks a role.
module SubjectRevocationConcurrencyObservation
  def exec_queries(...)
    signals = Thread.current[:subject_revocation_concurrency]
    return super unless lock_value && signals

    if signals[:side] == :console && [ User, CurrentScope::Role ].include?(klass)
      Thread.current[:subject_revocation_concurrency] = nil
      # With the old order the console already holds the role when the host
      # asks for it. With recipient-first locking, the host can finish first.
      if klass == CurrentScope::Role
        result = super
        signals[:console_lock].push(true)
        signals[:host_role_attempt].pop
        result
      else
        signals[:console_lock].push(true)
        signals[:host_role_attempt].pop
        super
      end
    elsif signals[:side] == :host && klass == CurrentScope::Role
      Thread.current[:subject_revocation_concurrency] = nil
      signals[:host_role_attempt].push(true)
      super
    else
      super
    end
  end
end
ActiveRecord::Relation.prepend(SubjectRevocationConcurrencyObservation)

class SubjectRevocationConcurrencyTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  %i[org scoped].each do |scope|
    test "#{scope} revocation waits for a host recipient update before authorizing" do
      skip "requires PostgreSQL row locks" unless ActiveRecord::Base.connection.adapter_name == "PostgreSQL"

      original_authorizer = CurrentScope.config.management_authorizer
      owner = User.create!(name: "Revocation owner")
      recipient = User.create!(name: "Revocation recipient")
      resource = Folder.create!(name: "Revocation folder")
      owner_role = CurrentScope::Role.create!(name: "Revocation owner role", full_access: true)
      role = CurrentScope::Role.create!(name: "Revocation reviewer")
      CurrentScope::RoleAssignment.create!(subject: owner, role: owner_role)
      klass = scope == :org ? CurrentScope::RoleAssignment : CurrentScope::ScopedRoleAssignment
      attributes = { subject: recipient, role: role }
      attributes[:resource] = resource if scope == :scoped
      assignment = klass.create!(attributes)
      CurrentScope.config.management_authorizer = lambda do |_actor, action:, role:, target:|
        target.nil? || target.name != "Protected"
      end
      ready, console_lock, host_role_attempt = Queue.new, Queue.new, Queue.new
      threads = []
      threads << Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          User.transaction do
            User.find(recipient.id).update!(name: "Protected")
            ready.push(true)
            console_lock.pop
            Thread.current[:subject_revocation_concurrency] = { side: :host, host_role_attempt: host_role_attempt }
            CurrentScope::Role.lock.find(owner_role.id)
          end
        end
      end
      Timeout.timeout(10) do
        ready.pop
        threads << Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            Thread.current[:subject_revocation_concurrency] = {
              side: :console, console_lock: console_lock, host_role_attempt: host_role_attempt
            }
            session = ActionDispatch::Integration::Session.new(Rails.application)
            path = scope == :org ? current_scope.role_assignment_url(assignment) : current_scope.scoped_role_assignment_url(assignment)
            session.delete path, headers: { "X-User-Id" => owner.id.to_s }
            session.response.status
          end
        end
        threads.first.value
        assert_equal 403, threads.last.value
      end
      assert_equal "Protected", recipient.reload.name
      assert klass.exists?(assignment.id), "the now-protected recipient must keep the grant"
    ensure
      Array(threads).each { |thread| thread.kill if thread.alive? }
      Array(threads).each(&:join)
      if owner
        CurrentScope.config.management_authorizer = original_authorizer
        targets = [ owner, recipient, role, owner_role ].compact.map { |record| record.to_gid.to_s }
        CurrentScope::Event.where(target: targets).delete_all
        CurrentScope::ScopedRoleAssignment.where(role: role).delete_all
        CurrentScope::RoleAssignment.where(role: [ role, owner_role ]).delete_all
        CurrentScope::RolePermission.where(role: [ role, owner_role ]).delete_all
        CurrentScope::Role.where(id: [ role.id, owner_role.id ]).delete_all
        Folder.where(id: resource.id).delete_all
        User.where(id: [ owner.id, recipient.id ]).delete_all
      end
    end
  end
end
