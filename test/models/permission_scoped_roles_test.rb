require "test_helper"

class PermissionScopedRolesTest < ActiveSupport::TestCase
  setup do
    @original = Project.respond_to?(:current_scope_grantable_permissions) ? Project.current_scope_grantable_permissions : nil
    Project.current_scope_grantable_permissions = [ "reports#index", "reports#show" ]
    @role = CurrentScope::Role.create!(name: "Custom viewer", permission_keys: [ "reports#show" ])
    @user = User.create!(name: "Reader")
    @report = Project.create!(name: "Test")
  end

  teardown { Project.current_scope_grantable_permissions = @original if Project.respond_to?(:current_scope_grantable_permissions=) }

  %i[scoped_grant permission].each do |kind|
    test "a deleted role makes #{kind} invalid without discarding its draft" do
      held_role = CurrentScope::Role.find(@role.id)
      held_role.permission_keys = [ "reports#approve" ]
      held_role.name = "Unsaved name"
      record = if kind == :scoped_grant
        CurrentScope::ScopedRoleAssignment.new(subject: @user, resource: @report, role: held_role)
      else
        CurrentScope::RolePermission.new(role: held_role, permission_key: "reports#index")
      end
      CurrentScope::Role.find(@role.id).destroy!

      assert_not record.valid?
      assert record.errors.of_kind?(:role, :invalid)
      assert_not record.save
      assert_raises(ActiveRecord::RecordInvalid) { record.save! }
      assert_not record.persisted?
      assert_equal [ "reports#approve" ], held_role.permission_keys
      assert_equal "Unsaved name", held_role.name
    end
  end

  test "custom role names work through scoped assignment and resolver" do
    CurrentScope::ScopedRoleAssignment.create!(subject: @user, resource: @report, role: @role)
    assert CurrentScope.allowed?("reports#show", subject: @user, record: @report)
  end

  test "a grant validates persisted permissions without discarding the caller staged bundle" do
    @role.permission_keys = [ "reports#approve" ]
    grant = CurrentScope::ScopedRoleAssignment.new(subject: @user, resource: @report, role: @role)
    assert grant.valid?
    assert_equal [ "reports#approve" ], @role.permission_keys
    assert_equal [ "reports#show" ], CurrentScope::Role.find(@role.id).permission_keys
  end

  test "a staged safe bundle cannot disguise an incompatible persisted role" do
    @role.update!(permission_keys: [ "reports#approve" ])
    @role.permission_keys = [ "reports#show" ]
    @role.name = "Staged name"
    grant = CurrentScope::ScopedRoleAssignment.new(subject: @user, resource: @report, role: @role)
    assert_not grant.valid?
    assert_equal [ "reports#show" ], @role.permission_keys
    assert_equal "Staged name", @role.name
  end

  test "new roles cannot autosave an out-of-ceiling join through a scoped grant" do
    draft = CurrentScope::Role.new(name: "Unsaved approver")
    draft.role_permissions.build(permission_key: "reports#approve")
    grant = CurrentScope::ScopedRoleAssignment.new(subject: @user, resource: @report, role: draft)

    assert_not grant.save
    assert_not CurrentScope::Role.exists?(name: "Unsaved approver")
    assert_equal [ "reports#approve" ], draft.permission_keys
    assert_not draft.grants?("reports#approve")
  end

  test "permission eligibility accepts existing role names and rejects missing names" do
    assert Project.current_scope_grants_role?(@role.name)
    assert_not Project.current_scope_grants_role?("Missing role")
    @role.update!(permission_keys: [ "reports#approve" ])
    assert_not Project.current_scope_grants_role?(@role.name)
  end

  test "permission and name restrictions combine without widening either" do
    declare_grantable_roles(Project, [ "Different name" ])
    assert_not Project.current_scope_grants_role?(@role)
    declare_grantable_roles(Project, [ @role.name ])
    assert Project.current_scope_grants_role?(@role)
    Project.current_scope_grantable_permissions = []
    assert_not Project.current_scope_grants_role?(@role)
    assert Project.current_scope_locked_down?
  end

  test "an empty permission ceiling explains that no scoped role is accepted" do
    Project.current_scope_grantable_permissions = []
    grant = CurrentScope::ScopedRoleAssignment.new(subject: @user, resource: @report, role: @role)

    assert_not grant.save
    assert_includes grant.errors.full_messages.to_sentence, "its permission ceiling accepts no scoped roles"
  end

  test "mixed and full access bundles are refused" do
    [ { permission_keys: [ "reports#show", "reports#approve" ] }, { full_access: true } ].each do |attributes|
      @role.update!(attributes)
      grant = CurrentScope::ScopedRoleAssignment.new(subject: @user, resource: @report, role: @role)
      assert_not grant.save
      @role.update!(full_access: false, permission_keys: [ "reports#show" ])
    end
  end

  test "removing all permissions leaves existing scoped assignments inert" do
    grant = CurrentScope::ScopedRoleAssignment.create!(subject: @user, resource: @report, role: @role)
    assert @role.update(permission_keys: [])
    assert CurrentScope::ScopedRoleAssignment.exists?(grant.id)
    assert_not CurrentScope.allowed?("reports#show", subject: @user, record: @report)
  end

  test "editing a held scoped role cannot widen past the resource ceiling" do
    CurrentScope::ScopedRoleAssignment.create!(subject: @user, resource: @report, role: @role)
    assert_not @role.update(permission_keys: [ "reports#show", "reports#approve" ])
    assert_equal [ "reports#show" ], @role.reload.permission_keys
    assert_not @role.update(full_access: true)
    assert_not @role.reload.full_access?
    assert @role.update(name: "Renamed viewer", permission_keys: [ "reports#index", "reports#show" ])
  end
  test "direct permission creation and replacement cannot widen a scoped grant" do
    CurrentScope::ScopedRoleAssignment.create!(subject: @user, resource: @report, role: @role)
    added = @role.role_permissions.build(permission_key: "reports#approve")
    assert_not added.save
    assert_equal [ "reports#show" ], @role.reload.permission_keys
    permission = @role.role_permissions.first
    assert_not permission.update(permission_key: "reports#approve")
    assert_equal "reports#show", permission.reload.permission_key
    assert_not CurrentScope.allowed?("reports#approve", subject: @user, record: @report)
    assert @role.role_permissions.create!(permission_key: "reports#index").persisted?
  end

  test "moving a permission checks the destination role ceiling atomically" do
    CurrentScope::ScopedRoleAssignment.create!(subject: @user, resource: @report, role: @role)
    source = CurrentScope::Role.create!(name: "Approver", permission_keys: [ "reports#approve" ])
    permission = source.role_permissions.first
    assert_not permission.update(role: @role)
    assert_equal source.id, permission.reload.role_id
    assert_equal [ "reports#show" ], @role.reload.permission_keys
  end
  test "fresh scoped grants block permission edits after the association was loaded" do
    @role.scoped_role_assignments.load
    CurrentScope::ScopedRoleAssignment.create!(subject: @user, resource: @report, role: CurrentScope::Role.find(@role.id))
    assert_not @role.update(permission_keys: [ "reports#approve" ])
    assert_equal [ "reports#show" ], @role.reload.permission_keys
    assert_not CurrentScope.allowed?("reports#approve", subject: @user, record: @report)
  end

  test "fresh scoped grants block full access promotion after the association was loaded" do
    @role.scoped_role_assignments.load
    CurrentScope::ScopedRoleAssignment.create!(subject: @user, resource: @report, role: CurrentScope::Role.find(@role.id))
    assert_not @role.update(full_access: true)
    assert_not @role.reload.full_access?
  end

  test "undeclared resources do not reread the already loaded role on grant validation" do
    Project.current_scope_grantable_permissions = nil
    grant = CurrentScope::ScopedRoleAssignment.new(subject: @user, resource: @report, role: @role)
    queries = capture_selects { assert grant.valid? }

    assert_empty queries.grep(/FROM ["`]current_scope_roles["`]/), queries.join("\n")
  end

  test "an unchanged submitted bundle does not scan scoped grants" do
    CurrentScope::ScopedRoleAssignment.create!(subject: @user, resource: @report, role: @role)
    queries = capture_selects { assert @role.update(permission_keys: [ "reports#show" ]) }

    assert_empty queries.grep(/FROM ["`]current_scope_scoped_role_assignments["`]/), queries.join("\n")
    assert_equal [ "reports#show" ], @role.reload.permission_keys

    @role.role_permissions.load
    CurrentScope::Role.find(@role.id).update!(permission_keys: [ "reports#index" ])
    queries = capture_selects { assert @role.update(permission_keys: [ "reports#show" ]) }
    assert queries.any? { |sql| sql.match?(/FROM ["`]current_scope_scoped_role_assignments["`]/) },
      "the stale loaded bundle must not turn a real change into a no-op"
    assert_equal [ "reports#show" ], @role.reload.permission_keys
  end

  test "full access demotion checks one permission bundle per governing class" do
    Project.current_scope_grantable_permissions = nil
    @role.update!(full_access: true)
    CurrentScope::ScopedRoleAssignment.create!(subject: @user, resource: @report, role: @role)
    counts = []
    2.times do |iteration|
      if iteration == 1
        Project.current_scope_grantable_permissions = nil
        8.times do |i|
          resource = Project.create!(name: "Additional #{i}")
          CurrentScope::ScopedRoleAssignment.create!(subject: @user, resource: resource, role: @role)
        end
      end
      Project.current_scope_grantable_permissions = [ "reports#show" ]
      candidate = CurrentScope::Role.find(@role.id)
      candidate.full_access = false
      queries = capture_selects { assert candidate.valid? }
      counts << queries.count { |sql| sql.include?("current_scope_role_permissions") }
    end
    assert_equal counts.first, counts.last, "bundle SELECTs grew from #{counts.first} to #{counts.last}"
  end

  test "a cached old bundle cannot bypass the ceiling after persisted permissions change" do
    ActiveRecord::Base.cache do
      assert_equal [ "reports#show" ], @role.role_permissions.where(nil).pluck(:permission_key)
      # Real writes with Rails' cache-preserving mode reproduce the stale read
      # left by a writer in another process, without mocking database results.
      ActiveRecord::Base.uncached(dirties: false) do
        Project.current_scope_grantable_permissions = [ "reports#index" ]
        fresh_role = CurrentScope::Role.find(@role.id)
        fresh_role.update!(permission_keys: [ "reports#index" ])
        CurrentScope::ScopedRoleAssignment.create!(subject: @user, resource: @report, role: fresh_role)
      end
      assert_equal [ "reports#show" ], @role.role_permissions.where(nil).pluck(:permission_key),
        "precondition: the old permission SELECT remains cached"
      assert_equal [ "reports#index" ], ActiveRecord::Base.uncached { CurrentScope::Role.find(@role.id).permission_keys }

      assert_not @role.update(permission_keys: [ "reports#show" ]),
        "a cached old bundle must not classify a forbidden widening as a no-op"
      assert_equal [ "reports#index" ], @role.reload.permission_keys
    end
  end

  test "scoped grant validation refuses a widened bundle despite a cached safe permission read" do
    ActiveRecord::Base.cache do
      assert_equal [ "reports#show" ], @role.permission_keys
      ActiveRecord::Base.uncached(dirties: false) do
        CurrentScope::Role.find(@role.id).update!(permission_keys: [ "reports#approve" ])
      end
      assert_equal [ "reports#show" ], @role.permission_keys, "precondition: the safe bundle remains cached"
      @role.permission_keys = [ "reports#index" ]
      grant = CurrentScope::ScopedRoleAssignment.new(subject: @user, resource: @report, role: @role)

      assert_not grant.save, "a fresh locked role must not use stale cached permissions"
      assert_equal [ "reports#index" ], @role.permission_keys, "validation preserves the caller draft"
      assert_not CurrentScope::ScopedRoleAssignment.exists?(subject: @user, resource: @report, role: @role)
    end
  end

  test "direct permission creation accepts a narrowed bundle despite cached old siblings" do
    @role.update!(permission_keys: [ "reports#show", "reports#approve" ])
    ActiveRecord::Base.cache do
      old_keys = @role.role_permissions.where.not(id: nil).pluck(:permission_key)
      assert_includes old_keys, "reports#approve"
      ActiveRecord::Base.uncached(dirties: false) do
        fresh_role = CurrentScope::Role.find(@role.id)
        fresh_role.update!(permission_keys: [ "reports#show" ])
        CurrentScope::ScopedRoleAssignment.create!(subject: @user, resource: @report, role: fresh_role)
      end
      assert_equal old_keys, @role.role_permissions.where.not(id: nil).pluck(:permission_key),
        "precondition: removed permissions remain in the cached sibling query"
      added = @role.role_permissions.build(permission_key: "reports#index")

      assert added.save, added.errors.full_messages.join(", ")
      assert_equal [ "reports#index", "reports#show" ], @role.reload.permission_keys.sort
    end
  end

  test "full access demotion cannot use stale loaded permissions" do
    assert_demotion_checks_stored_permissions(loaded: true)
  end

  test "full access demotion cannot use stale SQL cached permissions" do
    assert_demotion_checks_stored_permissions(loaded: false)
  end

  test "renaming a held role preserves name admission rules without blocking safe bundle edits" do
    declare_grantable_roles(Project, [ @role.name ])
    grant = CurrentScope::ScopedRoleAssignment.create!(subject: @user, resource: @report, role: @role)
    assert @role.update(name: "First rename")
    assert @role.update(name: "Console rename", permission_keys: [ "reports#show" ]), @role.errors.full_messages.join(", ")
    assert CurrentScope::ScopedRoleAssignment.exists?(grant.id)
    assert_not grant.reload.valid?, "saving a scoped assignment still checks its role name"
    assert @role.update(permission_keys: [ "reports#index" ]), @role.errors.full_messages.join(", ")
    assert @role.role_permissions.create!(permission_key: "reports#show").persisted?
    assert_not @role.update(permission_keys: [ "reports#approve" ])
    assert_equal [ "reports#index", "reports#show" ], @role.reload.permission_keys.sort
    assert_not @role.update(full_access: true)
    @role.reload

    Project.define_singleton_method(:current_scope_grants_role?) { |_role| false }
    custom_rule = true
    assert_not @role.update(permission_keys: [ "reports#show" ]), "a host override remains authoritative"
  ensure
    Project.singleton_class.send(:remove_method, :current_scope_grants_role?) if custom_rule
  end

  test "a fitting bundle with an unlisted name explains the name restriction" do
    declare_grantable_roles(Project, [ "Named viewer" ])
    grant = CurrentScope::ScopedRoleAssignment.new(subject: @user, resource: @report, role: @role)
    assert_not grant.valid?
    assert_includes grant.errors[:role].first, "it accepts Named viewer"
    assert_not_includes grant.errors[:role].first, "permission ceiling"

    @role.update!(permission_keys: [ "reports#approve" ])
    assert_not grant.valid?
    assert_includes grant.errors[:role].first, "permission ceiling"
  end

  test "a name refusal explains the fresh bundle rather than cached or staged keys" do
    declare_grantable_roles(Project, [ "Named viewer" ])
    @role.update!(permission_keys: [ "reports#approve" ])
    ActiveRecord::Base.cache do
      assert_equal [ "reports#approve" ], @role.permission_keys
      ActiveRecord::Base.uncached(dirties: false) do
        CurrentScope::Role.find(@role.id).update!(permission_keys: [ "reports#show" ])
      end
      @role.permission_keys = [ "reports#approve" ]
      grant = CurrentScope::ScopedRoleAssignment.new(subject: @user, resource: @report, role: @role)
      assert_not grant.valid?
      assert_includes grant.errors[:role].first, "it accepts Named viewer"
      assert_not_includes grant.errors[:role].first, "permission ceiling"
      assert_equal [ "reports#approve" ], @role.permission_keys
    end
  end

  private

  def assert_demotion_checks_stored_permissions(loaded:)
    Project.current_scope_grantable_permissions = nil
    @role.update!(full_access: true)
    CurrentScope::ScopedRoleAssignment.create!(subject: @user, resource: @report, role: @role)
    ActiveRecord::Base.cache do
      candidate = CurrentScope::Role.find(@role.id)
      candidate.role_permissions.load if loaded
      assert_equal [ "reports#show" ], candidate.permission_keys
      ActiveRecord::Base.uncached(dirties: false) do
        CurrentScope::Role.find(@role.id).update!(permission_keys: [ "reports#approve" ])
      end
      Project.current_scope_grantable_permissions = [ "reports#show", "reports#index" ]
      candidate.full_access = false

      assert_not candidate.save, "demotion must check persisted permissions, not a stale caller bundle"
      assert @role.reload.full_access?
      assert_equal [ "reports#approve" ], @role.permission_keys
      if loaded
        assert candidate.role_permissions.loaded?, "the caller's loaded association remains intact"
        assert_equal [ "reports#show" ], candidate.role_permissions.map(&:permission_key)
      else
        draft = candidate.role_permissions.build(permission_key: "reports#index")
        assert_not candidate.valid?
        assert_includes candidate.role_permissions.target, draft
        assert draft.new_record?, "the caller's join draft must not be persisted or discarded"
      end
    end
  end

  def capture_selects
    queries = []
    watcher = ->(*, payload) { queries << payload[:sql] if payload[:sql].match?(/\ASELECT/i) }
    ActiveRecord::Base.uncached do
      ActiveSupport::Notifications.subscribed(watcher, "sql.active_record") { yield }
    end
    queries
  end
end
