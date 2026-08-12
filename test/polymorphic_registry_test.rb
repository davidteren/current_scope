require "test_helper"

# #155 U2: custom tokens reverse through a closed registry, never a live
# descendant scan at lookup time.
class PolymorphicRegistryTest < ActiveSupport::TestCase
  setup do
    TokenDocument
    Folder
    CurrentScope.rebuild_polymorphic_registry!
  end

  teardown do
    CurrentScope.config.polymorphic_class_names = {}
    CurrentScope.rebuild_polymorphic_registry!
  end

  test "TokenDocument's custom token reverse-resolves after rebuild" do
    assert_equal TokenDocument, CurrentScope.polymorphic_class("token_docs")
  end

  test "an unmapped token stays nil" do
    assert_nil CurrentScope.polymorphic_class("old_token")
  end

  test "current_scope_resolved_record loads via find_by, not the association" do
    user = User.create!(name: "Holder")
    doc = TokenDocument.create!(name: "Mapped")
    role = CurrentScope::Role.create!(name: "MappedViewer")
    now = Time.current
    CurrentScope::ScopedRoleAssignment.insert!({
      role_id: role.id,
      subject_type: "User",
      subject_id: user.id.to_s,
      resource_type: "token_docs",
      resource_id: doc.id.to_s,
      created_at: now,
      updated_at: now
    })
    grant = CurrentScope::ScopedRoleAssignment.find_by!(resource_type: "token_docs", resource_id: doc.id.to_s)

    assert_equal doc, grant.current_scope_resolved_record("resource")
  end

  test "create! with a live custom-token record works once the token is registered" do
    user = User.create!(name: "Writer")
    doc = TokenDocument.create!(name: "Live")
    role = CurrentScope::Role.create!(name: "LiveWriter")

    grant = CurrentScope::ScopedRoleAssignment.create!(subject: user, role: role, resource: doc)
    assert_equal "token_docs", grant.resource_type
    assert_equal doc, grant.current_scope_resolved_record("resource")
  end

  test "two classes claiming one token raise on rebuild" do
    original = Folder.method(:polymorphic_name)
    Folder.define_singleton_method(:polymorphic_name) { "token_docs" }

    error = assert_raises(CurrentScope::ConfigurationError) do
      CurrentScope.rebuild_polymorphic_registry!
    end
    assert_match(/token_docs/, error.message)
    assert_match(/Folder/, error.message)
  ensure
    Folder.define_singleton_method(:polymorphic_name, original)
    CurrentScope.rebuild_polymorphic_registry!
  end

  test "config may restate the same class and may not name a second class" do
    CurrentScope.config.polymorphic_class_names = { "token_docs" => "TokenDocument" }
    assert_nothing_raised { CurrentScope.rebuild_polymorphic_registry! }

    CurrentScope.config.polymorphic_class_names = { "token_docs" => "Folder" }
    assert_raises(CurrentScope::ConfigurationError) { CurrentScope.rebuild_polymorphic_registry! }
  ensure
    CurrentScope.config.polymorphic_class_names = {}
    CurrentScope.rebuild_polymorphic_registry!
  end

  test "polymorphic_class_names writer rejects a non-hash" do
    config = CurrentScope::Configuration.new
    assert_raises(CurrentScope::ConfigurationError) { config.polymorphic_class_names = "token_docs" }
    assert_equal({}, config.polymorphic_class_names)
  end
end
