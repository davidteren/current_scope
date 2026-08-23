require "test_helper"

class DefinitionsDocumentTest < ActiveSupport::TestCase
  setup do
    @owner = CurrentScope::Role.create!(name: "Owner", full_access: true, description: "All access")
    @editor = CurrentScope::Role.create!(name: "Editor", description: "Edits reports")
    @editor.permission_keys = [ "reports#show", "reports#index" ]
    @editor.save!
  end

  test "export is deterministic and sorts roles and keys" do
    yaml = CurrentScope.export_definitions
    again = CurrentScope.export_definitions
    assert_equal yaml, again

    document = CurrentScope::DefinitionsDocument.parse(yaml)
    assert_equal [ "Editor", "Owner" ], document.roles.map(&:name)
    assert_equal [ "reports#index", "reports#show" ], document.roles.first.permission_keys
    assert_equal true, document.roles.last.full_access
    assert_equal "All access", document.roles.last.description
  end

  test "an empty roles table exports a valid document with an empty list" do
    CurrentScope::Role.destroy_all
    yaml = CurrentScope.export_definitions
    document = CurrentScope::DefinitionsDocument.parse(yaml)
    assert_equal [], document.roles
    assert_match(/roles: \[\]/, yaml)
  end

  test "a nil description serializes as an empty string" do
    CurrentScope::Role.create!(name: "Blank")
    yaml = CurrentScope.export_definitions
    blank = CurrentScope::DefinitionsDocument.parse(yaml).roles.find { |role| role.name == "Blank" }
    assert_equal "", blank.description
  end

  test "two exports of the same rows are byte-identical" do
    first = CurrentScope::DefinitionsDocument.from_live.to_yaml
    second = CurrentScope::DefinitionsDocument.from_live.to_yaml
    assert_equal first, second
  end

  test "diff names one added key on Editor" do
    yaml = CurrentScope.export_definitions
    document = CurrentScope::DefinitionsDocument.parse(yaml)
    editor = document.roles.find { |role| role.name == "Editor" }
    edited = document.roles.map do |role|
      next role unless role.name == "Editor"

      role.with(permission_keys: (editor.permission_keys + [ "reports#approve" ]).sort)
    end
    incoming = CurrentScope::DefinitionsDocument.new(edited)
    diff = incoming.diff

    change = diff.change_for("Editor")
    assert_equal [ "reports#approve" ], change.keys_added
    assert_equal [], change.keys_removed
    assert_match(/role Editor gains reports#approve/, diff.to_s)
  end

  test "diff names a new role under added" do
    yaml = CurrentScope.export_definitions
    extra = CurrentScope::DefinitionsDocument::RoleSpec.new(
      name: "Auditor", description: "", full_access: false, permission_keys: [ "reports#index" ]
    )
    incoming = CurrentScope::DefinitionsDocument.parse(yaml)
    incoming = CurrentScope::DefinitionsDocument.new(incoming.roles + [ extra ])
    diff = incoming.diff

    assert_equal [ "Auditor" ], diff.added_names
    assert_match(/^add role Auditor$/, diff.to_s)
  end

  test "diff names a removed role after FA demotions, with holder counts" do
    holder = User.create!(name: "Pat")
    CurrentScope::RoleAssignment.create!(subject: holder, role: @editor)
    report = Report.create!(title: "Q1", requested_by: holder)
    CurrentScope::ScopedRoleAssignment.create!(
      subject: holder, role: @editor, resource: report
    )

    yaml = CurrentScope.export_definitions
    document = CurrentScope::DefinitionsDocument.parse(yaml)
    without_editor = CurrentScope::DefinitionsDocument.new(
      document.roles.reject { |role| role.name == "Editor" }
    )
    diff = without_editor.diff
    removed = diff.removed_for("Editor")

    assert_equal "Editor", removed.name
    assert_equal 1, removed.org_holders
    assert_equal 1, removed.scoped_holders
    printed = diff.to_s.lines.map(&:chomp)
    assert_equal "remove role Editor (1 org holders, 1 scoped holders)", printed.first
  end

  test "printed order is removals, then FA demotions, then key removals, then adds" do
    yaml = CurrentScope.export_definitions
    document = CurrentScope::DefinitionsDocument.parse(yaml)
    roles = document.roles.map do |role|
      case role.name
      when "Owner"
        role.with(full_access: false)
      when "Editor"
        role.with(permission_keys: [ "reports#index" ])
      else
        role
      end
    end
    auditor = CurrentScope::DefinitionsDocument::RoleSpec.new(
      name: "Auditor", description: "", full_access: false, permission_keys: []
    )
    incoming = CurrentScope::DefinitionsDocument.new(roles + [ auditor ])
    CurrentScope::Role.create!(name: "Spare")
    incoming = CurrentScope::DefinitionsDocument.new(incoming.roles)
    # Spare is live but absent from incoming → removal. Rebuild incoming without Spare (already).
    printed = incoming.diff.to_s.lines.map(&:chomp)

    remove_at = printed.index { |line| line.start_with?("remove role Spare") }
    demote_at = printed.index { |line| line.include?("full_access false") }
    lose_at = printed.index { |line| line.include?("loses reports#show") }
    add_at = printed.index { |line| line.start_with?("add role Auditor") }
    assert remove_at < demote_at
    assert demote_at < lose_at
    assert lose_at < add_at
  end

  test "diff names a full_access flip" do
    yaml = CurrentScope.export_definitions
    document = CurrentScope::DefinitionsDocument.parse(yaml)
    flipped = document.roles.map do |role|
      role.name == "Owner" ? role.with(full_access: false) : role
    end
    diff = CurrentScope::DefinitionsDocument.new(flipped).diff
    change = diff.change_for("Owner")

    assert_equal true, change.full_access_from
    assert_equal false, change.full_access_to
    assert_match(/role Owner full_access false/, diff.to_s)
  end

  test "an identical document yields an empty diff" do
    yaml = CurrentScope.export_definitions
    diff = CurrentScope.diff_definitions(yaml)
    assert diff.empty?
    assert_equal "", diff.to_s
  end

  test "parse turns a refused YAML construct into InvalidDocument" do
    yaml = <<~YAML
      apiVersion: #{CurrentScope::DefinitionsDocument::API_VERSION}
      roles:
        - name: Editor
          permission_keys: &base
            - reports#index
        - name: Reviewer
          permission_keys: *base
    YAML
    assert_raises CurrentScope::DefinitionsDocument::InvalidDocument do
      CurrentScope::DefinitionsDocument.parse(yaml)
    end
  end

  test "parse refuses a full_access value that is not true or false" do
    yaml = <<~YAML
      apiVersion: #{CurrentScope::DefinitionsDocument::API_VERSION}
      roles:
        - name: Owner
          full_access: ture
    YAML
    error = assert_raises CurrentScope::DefinitionsDocument::InvalidDocument do
      CurrentScope::DefinitionsDocument.parse(yaml)
    end
    assert_match(/full_access must be true or false/, error.message)
  end

  test "parse refuses a missing or foreign apiVersion" do
    assert_raises CurrentScope::DefinitionsDocument::InvalidDocument do
      CurrentScope::DefinitionsDocument.parse("roles: []\n")
    end
    assert_raises CurrentScope::DefinitionsDocument::InvalidDocument do
      CurrentScope::DefinitionsDocument.parse("apiVersion: other\nroles: []\n")
    end
  end
end
