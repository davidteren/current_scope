require "test_helper"
require "current_scope/test_helpers"

class DefinitionsImportTest < ActiveSupport::TestCase
  include CurrentScope::TestHelpers

  setup do
    @actor = User.create!(name: "Operator")
    @owner = CurrentScope::Role.create!(name: "Owner", full_access: true)
    @editor = CurrentScope::Role.create!(name: "Editor")
    @editor.permission_keys = [ "reports#index" ]
    @editor.save!
    @tmpdir = Dir.mktmpdir
  end

  teardown do
    FileUtils.remove_entry(@tmpdir)
    CurrentScope.config.audit = true
  end

  def document_from_live
    CurrentScope::DefinitionsDocument.from_live
  end

  def with_key(name, extra_keys)
    roles = document_from_live.roles.map do |role|
      next role unless role.name == name

      role.with(permission_keys: (role.permission_keys + extra_keys).sort)
    end
    CurrentScope::DefinitionsDocument.new(roles)
  end

  def snapshot_path
    File.join(@tmpdir, "roles.yml.pre.yml")
  end

  test "adding a key with confirm is idempotent on the second apply" do
    incoming = with_key("Editor", [ "reports#approve" ])
    incoming.apply(confirm: true, actor: @actor, snapshot_path: snapshot_path)

    @editor.reload
    assert_includes @editor.permission_keys, "reports#approve"

    assert_no_difference -> { CurrentScope::Event.where(event: "definitions.applied").count } do
      incoming.apply(confirm: true, actor: @actor, snapshot_path: snapshot_path)
    end
    assert_equal [ "reports#approve", "reports#index" ].sort, @editor.reload.permission_keys.sort
  end

  test "non-production empty table applies without confirm" do
    CurrentScope::Role.destroy_all
    yaml = <<~YAML
      apiVersion: current_scope/definitions-v1
      roles:
      - name: Owner
        description: ""
        full_access: true
        permission_keys: []
    YAML
    CurrentScope.import_definitions(yaml, actor: @actor, snapshot_path: snapshot_path)
    assert CurrentScope::Role.find_by(name: "Owner").full_access?
  end

  test "populated without confirm writes nothing" do
    incoming = with_key("Editor", [ "reports#approve" ])
    assert_raises CurrentScope::DefinitionsDocument::ConfirmRequired do
      incoming.apply(actor: @actor, snapshot_path: snapshot_path)
    end
    assert_not_includes @editor.reload.permission_keys, "reports#approve"
  end

  test "production empty table without confirm writes nothing" do
    CurrentScope::Role.destroy_all
    original = Rails.env
    Rails.env = "production"
    yaml = <<~YAML
      apiVersion: current_scope/definitions-v1
      roles:
      - name: Owner
        description: ""
        full_access: true
        permission_keys: []
    YAML
    assert_raises CurrentScope::DefinitionsDocument::ConfirmRequired do
      CurrentScope.import_definitions(yaml, actor: @actor, snapshot_path: snapshot_path)
    end
    assert_equal 0, CurrentScope::Role.count
  ensure
    Rails.env = original
  end

  test "a document key not in the catalog writes nothing" do
    incoming = with_key("Editor", [ "not_a_real#action" ])
    assert_raises CurrentScope::DefinitionsDocument::UnknownCatalogKey do
      incoming.apply(confirm: true, actor: @actor, snapshot_path: snapshot_path)
    end
    assert_not_includes @editor.reload.permission_keys, "not_a_real#action"
  end

  test "last held full-access demotion is refused and writes nothing" do
    holder = User.create!(name: "Lead")
    CurrentScope::RoleAssignment.create!(subject: holder, role: @owner)

    incoming = CurrentScope::DefinitionsDocument.new(
      document_from_live.roles.map { |role| role.name == "Owner" ? role.with(full_access: false) : role }
    )
    assert_raises CurrentScope::DefinitionsDocument::LastHolderLock do
      incoming.apply(confirm: true, actor: @actor, snapshot_path: snapshot_path)
    end
    assert @owner.reload.full_access?
  end

  test "document omitting a held role is refused and the grant remains" do
    holder = User.create!(name: "Pat")
    CurrentScope::RoleAssignment.create!(subject: holder, role: @editor)
    incoming = CurrentScope::DefinitionsDocument.new(
      document_from_live.roles.reject { |role| role.name == "Editor" }
    )
    error = assert_raises CurrentScope::DefinitionsDocument::HeldRoleDelete do
      incoming.apply(confirm: true, actor: @actor, snapshot_path: snapshot_path)
    end
    assert_match(/Editor/, error.message)
    assert_match(/1 org-wide/, error.message)
    assert CurrentScope::Role.exists?(name: "Editor")
    assert CurrentScope::RoleAssignment.exists?(subject: holder, role: @editor)
  end

  test "missing apiVersion writes nothing" do
    assert_raises CurrentScope::DefinitionsDocument::InvalidDocument do
      CurrentScope.import_definitions("roles: []\n", confirm: true, actor: @actor)
    end
    assert CurrentScope::Role.exists?(name: "Owner")
  end

  test "deleting an unassigned spare full-access role is allowed when another held full-access remains" do
    holder = User.create!(name: "Lead")
    CurrentScope::RoleAssignment.create!(subject: holder, role: @owner)
    spare = CurrentScope::Role.create!(name: "Spare", full_access: true)
    incoming = CurrentScope::DefinitionsDocument.new(
      document_from_live.roles.reject { |role| role.name == "Spare" }
    )
    incoming.apply(confirm: true, actor: @actor, snapshot_path: snapshot_path)
    assert_nil CurrentScope::Role.find_by(name: "Spare")
    assert @owner.reload.full_access?
    assert_nil spare.class.find_by(id: spare.id)
  end

  test "demote held Owner while adding an unheld spare full-access role is refused" do
    holder = User.create!(name: "Lead")
    CurrentScope::RoleAssignment.create!(subject: holder, role: @owner)
    spare = CurrentScope::DefinitionsDocument::RoleSpec.new(
      name: "Spare", description: "", full_access: true, permission_keys: []
    )
    incoming = CurrentScope::DefinitionsDocument.new(
      document_from_live.roles.map { |role| role.name == "Owner" ? role.with(full_access: false) : role } + [ spare ]
    )
    assert_raises CurrentScope::DefinitionsDocument::LastHolderLock do
      incoming.apply(confirm: true, actor: @actor, snapshot_path: snapshot_path)
    end
    assert @owner.reload.full_access?
    assert_nil CurrentScope::Role.find_by(name: "Spare")
  end

  test "demoting the held Owner is allowed when the document promotes a held role" do
    CurrentScope::RoleAssignment.create!(subject: User.create!(name: "Lead"), role: @owner)
    CurrentScope::RoleAssignment.create!(subject: User.create!(name: "Pat"), role: @editor)

    incoming = CurrentScope::DefinitionsDocument.new(
      document_from_live.roles.map do |role|
        next role.with(full_access: false) if role.name == "Owner"
        next role.with(full_access: true) if role.name == "Editor"

        role
      end
    )
    incoming.apply(confirm: true, actor: @actor, snapshot_path: snapshot_path)

    assert_not @owner.reload.full_access?
    assert @editor.reload.full_access?, "a promoted held role keeps the console open"
  end

  test "rollback writes its undo point where the caller asks" do
    with_key("Editor", [ "reports#approve" ]).apply(confirm: true, actor: @actor, snapshot_path: snapshot_path)
    undo = File.join(@tmpdir, "undo.yml")

    CurrentScope.rollback_definitions(snapshot_path, confirm: true, actor: @actor, snapshot_path: undo)

    editor = CurrentScope::DefinitionsDocument.parse(undo).roles.find { |role| role.name == "Editor" }
    assert_includes editor.permission_keys, "reports#approve", "the undo point holds the pre-rollback world"
  end

  test "apply then rollback restores keys" do
    incoming = with_key("Editor", [ "reports#approve" ])
    incoming.apply(confirm: true, actor: @actor, snapshot_path: snapshot_path)
    assert_includes @editor.reload.permission_keys, "reports#approve"

    CurrentScope.rollback_definitions(snapshot_path, confirm: true, actor: @actor)
    assert_not_includes @editor.reload.permission_keys, "reports#approve"
    assert_equal [ "reports#index" ], @editor.permission_keys.sort
  end

  test "no-op apply writes no event" do
    yaml = CurrentScope.export_definitions
    assert_no_difference -> { CurrentScope::Event.count } do
      CurrentScope.import_definitions(yaml, confirm: true, actor: @actor, snapshot_path: snapshot_path)
    end
  end

  test "apply then rollback records one applied and one rolled_back row" do
    incoming = with_key("Editor", [ "reports#approve" ])
    incoming.apply(confirm: true, actor: @actor, snapshot_path: snapshot_path)
    CurrentScope.rollback_definitions(snapshot_path, confirm: true, actor: @actor)

    applied = CurrentScope::Event.find_by(event: "definitions.applied")
    rolled = CurrentScope::Event.find_by(event: "definitions.rolled_back")
    assert applied
    assert rolled
    assert_equal CurrentScope::Event::DEFINITIONS_TARGET, applied.target
    assert_equal "Role definitions", applied.target_label
    assert_equal snapshot_path, applied.details["snapshot"]
    assert_match(/gains reports#approve/, applied.details["diff"])
  end

  test "strict audit and a missing events table rolls back the apply" do
    CurrentScope.config.audit = :strict
    incoming = with_key("Editor", [ "reports#approve" ])
    original = CurrentScope::Event.method(:create!)
    CurrentScope::Event.define_singleton_method(:create!) do |*, **|
      raise ActiveRecord::StatementInvalid, "SQLite3::SQLException: no such table: current_scope_events"
    end

    assert_raises(ActiveRecord::StatementInvalid) do
      incoming.apply(confirm: true, actor: @actor, snapshot_path: snapshot_path)
    end
    assert_not_includes @editor.reload.permission_keys, "reports#approve"
  ensure
    CurrentScope::Event.define_singleton_method(:create!, original)
  end

  test "rollback of a missing snapshot raises and writes nothing" do
    assert_raises CurrentScope::DefinitionsDocument::SnapshotMissing do
      CurrentScope.rollback_definitions(File.join(@tmpdir, "missing.yml"), confirm: true, actor: @actor)
    end
    assert_equal [ "reports#index" ], @editor.reload.permission_keys.sort
  end

  test "populated rollback without confirm writes nothing" do
    incoming = with_key("Editor", [ "reports#approve" ])
    incoming.apply(confirm: true, actor: @actor, snapshot_path: snapshot_path)
    assert_raises CurrentScope::DefinitionsDocument::ConfirmRequired do
      CurrentScope.rollback_definitions(snapshot_path, actor: @actor)
    end
    assert_includes @editor.reload.permission_keys, "reports#approve"
  end

  test "rollback from the default snapshot path is idempotent" do
    default_path = CurrentScope::DefinitionsDocument.default_snapshot_path
    FileUtils.rm_f(default_path)
    with_key("Editor", [ "reports#approve" ]).apply(confirm: true, actor: @actor)
    assert_includes @editor.reload.permission_keys, "reports#approve"

    CurrentScope.rollback_definitions(default_path, confirm: true, actor: @actor)
    assert_not_includes @editor.reload.permission_keys, "reports#approve"
    assert File.file?("#{default_path}.pre.yml"), "the undo point moves aside instead of overwriting the snapshot"

    CurrentScope.rollback_definitions(default_path, confirm: true, actor: @actor)
    assert_not_includes @editor.reload.permission_keys, "reports#approve"
  ensure
    FileUtils.rm_f(default_path)
    FileUtils.rm_f("#{default_path}.pre.yml")
  end

  test "an apply that rolls back leaves the previous snapshot in place" do
    with_key("Editor", [ "reports#approve" ]).apply(confirm: true, actor: @actor, snapshot_path: snapshot_path)
    first_snapshot = File.read(snapshot_path)

    CurrentScope.config.audit = :strict
    original = CurrentScope::Event.method(:create!)
    CurrentScope::Event.define_singleton_method(:create!) do |*, **|
      raise ActiveRecord::StatementInvalid, "SQLite3::SQLException: no such table: current_scope_events"
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      with_key("Owner", [ "reports#approve" ]).apply(confirm: true, actor: @actor, snapshot_path: snapshot_path)
    end

    assert_equal first_snapshot, File.read(snapshot_path)
  ensure
    CurrentScope::Event.define_singleton_method(:create!, original) if original
  end
end
