require "test_helper"

# #155 U1: a grant stored under a custom polymorphic_name must appear in
# scope_for and agree with the per-record gate. This test is expected to fail
# on main, where granted_ids is queried with base_class.name.
class ScopeForCustomTokenTest < ActiveSupport::TestCase
  setup do
    @resolver = CurrentScope::Resolver.new
    @user = User.create!(name: "Holder")
    @doc = TokenDocument.create!(name: "Alpha")
    @role = CurrentScope::Role.create!(name: "TokenViewer")
    @role.role_permissions.create!(permission_key: "folders#index")
    @role.role_permissions.create!(permission_key: "folders#destroy")
    grant_on(@doc)
  end

  # belongs_to :resource is required, so validation loads the association and
  # Rails constantizes resource_type. A custom token is not a constant until
  # U2 registers it. U1 tests the query path, so write past validations.
  def grant_on(record, role: @role)
    now = Time.current
    CurrentScope::ScopedRoleAssignment.insert!({
      role_id: role.id,
      subject_type: @user.class.polymorphic_name,
      subject_id: @user.id.to_s,
      resource_type: record.class.polymorphic_name,
      resource_id: record.id.to_s,
      created_at: now,
      updated_at: now
    })
  end

  test "a scoped grant stores the custom polymorphic_name" do
    grant = CurrentScope::ScopedRoleAssignment.find_by!(
      subject_id: @user.id.to_s, resource_id: @doc.id.to_s, resource_type: "token_docs"
    )
    assert_equal "token_docs", grant.resource_type
  end

  test "scope_for includes the granted custom-token record" do
    result = @resolver.scope_for(subject: @user, model: TokenDocument, permission: "folders#index")
    assert_includes result, @doc
  end

  test "scope_for agrees with the per-record gate" do
    result = @resolver.scope_for(subject: @user, model: TokenDocument, permission: "folders#index")
    assert @resolver.allow?(subject: @user, permission: "folders#index", record: @doc)
    assert_equal [ @doc ], result.to_a
  end

  test "an ungranted subject sees none" do
    stranger = User.create!(name: "Stranger")
    result = @resolver.scope_for(subject: stranger, model: TokenDocument, permission: "folders#index")
    assert_empty result
  end

  test "a Document grant does not open TokenDocument" do
    invoice = Invoice.create!(title: "INV-x")
    grant_on(invoice)
    result = @resolver.scope_for(subject: @user, model: TokenDocument, permission: "folders#index")
    assert_equal [ @doc ], result.to_a
  end

  test "record-less non-read sees the same grant ids as scope_for" do
    listed = @resolver.scope_for(subject: @user, model: TokenDocument, permission: "folders#destroy")
    assert_includes listed, @doc
    assert @resolver.allow?(subject: @user, permission: "folders#destroy", record: TokenDocument)
  end

  test "a custom-token parent grant reaches children through ancestor_scope_for" do
    original = Project.method(:polymorphic_name)
    Project.define_singleton_method(:polymorphic_name) { "token_projects" }

    requester = User.create!(name: "Requester")
    project = Project.create!(name: "P-token")
    report = Report.create!(title: "R-token", project: project, requested_by: requester)
    viewer = CurrentScope::Role.create!(name: "TokenParentViewer")
    viewer.role_permissions.create!(permission_key: "reports#index")
    grant_on(project, role: viewer)

    assert_equal "token_projects",
                 CurrentScope::ScopedRoleAssignment.find_by!(
                   resource_id: project.id.to_s, resource_type: "token_projects"
                 ).resource_type
    result = @resolver.scope_for(subject: @user, model: Report, permission: "reports#index")
    assert_includes result, report
    assert_equal [ "Project", project.id ], CurrentScope::ParentChain.send(:identity, project)
    assert_equal "token_projects", CurrentScope.storage_token(Project)
  ensure
    Project.define_singleton_method(:polymorphic_name, original)
  end

  test "create! of a custom-token grant agrees with scope_for and allow?" do
    CurrentScope.rebuild_polymorphic_registry!
    user = User.create!(name: "Writer")
    doc = TokenDocument.create!(name: "LiveGrant")
    role = CurrentScope::Role.create!(name: "LiveTokenViewer")
    role.role_permissions.create!(permission_key: "folders#index")
    CurrentScope::ScopedRoleAssignment.create!(subject: user, role: role, resource: doc)

    result = @resolver.scope_for(subject: user, model: TokenDocument, permission: "folders#index")
    assert_includes result, doc
    assert @resolver.allow?(subject: user, permission: "folders#index", record: doc)
  end
end
