require "test_helper"
require "timeout"

# Coordinate at the real locking queries, without time-based sleeps. The host
# holds a recipient row when the console reaches its recipient lock.
module HostGrantConcurrencyObservation
  def exec_queries(...)
    if lock_value && (signals = Thread.current[:host_grant_concurrency])
      if klass == User && signals[:side] == :console
        Thread.current[:host_grant_concurrency] = nil
        signals[:grant].push(true)
        signals[:role_attempt].pop
      elsif klass == CurrentScope::Role && signals[:side] == :host
        Thread.current[:host_grant_concurrency] = nil
        signals[:role_attempt].push(true)
      end
    end
    super
  end
end
ActiveRecord::Relation.prepend(HostGrantConcurrencyObservation)

class HostGrantConcurrencyTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  test "host recipient updates and console scoped grants finish without deadlock" do
    skip "requires PostgreSQL row locks" unless ActiveRecord::Base.connection.adapter_name == "PostgreSQL"

    owner = User.create!(name: "Concurrent owner")
    member = User.create!(name: "Concurrent member")
    project = Project.create!(name: "Concurrent project")
    owner_role = CurrentScope::Role.create!(name: "Concurrent owner role", full_access: true)
    role = CurrentScope::Role.create!(name: "Concurrent scoped role", permission_keys: [ "reports#show" ])
    CurrentScope::RoleAssignment.create!(subject: owner, role: owner_role)
    ready, grant, role_attempt = Queue.new, Queue.new, Queue.new
    threads = []
    threads << Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        User.transaction do
          User.find(member.id).update!(name: "Host update saved")
          ready.push(true)
          grant.pop
          Thread.current[:host_grant_concurrency] = { side: :host, role_attempt: role_attempt }
          CurrentScope::ScopedRoleAssignment.create!(subject: member, resource: project, role: role)
        end
      end
    end
    Timeout.timeout(10) do
      ready.pop
      threads << Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Thread.current[:host_grant_concurrency] = { side: :console, grant: grant, role_attempt: role_attempt }
          session = ActionDispatch::Integration::Session.new(Rails.application)
          session.post current_scope.scoped_role_assignments_url,
            params: { subject_gid: member.to_gid.to_s, resource_gid: project.to_gid.to_s, role_id: role.id },
            headers: { "X-User-Id" => owner.id.to_s }
          session.response.status
        end
      end
      threads.first.value
      assert_equal 302, threads.last.value
    end
    assert_equal "Host update saved", member.reload.name
    assert_equal 1, CurrentScope::ScopedRoleAssignment.where(subject: member, resource: project, role: role).count
  ensure
    Array(threads).each { |thread| thread.kill if thread.alive? }
    Array(threads).each(&:join)
    if owner
      targets = [ owner, member, role, owner_role ].compact.map { |record| record.to_gid.to_s }
      CurrentScope::Event.where(target: targets).delete_all
      CurrentScope::ScopedRoleAssignment.where(role: role).delete_all
      CurrentScope::RoleAssignment.where(role: owner_role).delete_all
      CurrentScope::RolePermission.where(role: [ role, owner_role ]).delete_all
      CurrentScope::Role.where(id: [ role&.id, owner_role&.id ]).delete_all
      Project.where(id: project&.id).delete_all
      User.where(id: [ owner.id, member&.id ]).delete_all
    end
  end
end
