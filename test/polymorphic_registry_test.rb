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

  test "Rails reverse cannot override a registered token owner" do
    CurrentScope.rebuild_polymorphic_registry!
    CurrentScope.polymorphic_registry.dup.tap do |map|
      map["User"] = TokenDocument
      CurrentScope.instance_variable_set(:@polymorphic_registry, map.freeze)
    end

    error = assert_raises(CurrentScope::ConfigurationError) do
      CurrentScope.polymorphic_class("User")
    end
    assert_match(/User/, error.message)
    assert_match(/TokenDocument/, error.message)
  ensure
    CurrentScope.rebuild_polymorphic_registry!
  end

  test "a custom token that is another class's constant uses the registry" do
    original = Folder.method(:polymorphic_name)
    Folder.define_singleton_method(:polymorphic_name) { "TokenDocument" }
    CurrentScope.rebuild_polymorphic_registry!

    assert_equal Folder, CurrentScope.polymorphic_class("TokenDocument")
    assert_equal TokenDocument, CurrentScope.polymorphic_class("token_docs")
  ensure
    Folder.define_singleton_method(:polymorphic_name, original)
    CurrentScope.rebuild_polymorphic_registry!
  end

  test "a failed rebuild leaves the registry empty, not the previous map" do
    assert_equal TokenDocument, CurrentScope.polymorphic_class("token_docs")
    original = Folder.method(:polymorphic_name)
    Folder.define_singleton_method(:polymorphic_name) { "token_docs" }

    assert_raises(CurrentScope::ConfigurationError) do
      CurrentScope.rebuild_polymorphic_registry!
    end
    # The distinguishing claim of the title: the map is emptied, not left holding
    # the previous (now-stale) entries.
    assert_empty CurrentScope.polymorphic_registry
    assert_raises(CurrentScope::ConfigurationError) do
      CurrentScope.polymorphic_class("token_docs")
    end
  ensure
    Folder.define_singleton_method(:polymorphic_name, original)
    CurrentScope.rebuild_polymorphic_registry!
  end

  test "an unmapped token stays nil" do
    assert_nil CurrentScope.polymorphic_class("old_token")
  end

  test "a custom token shared by an STI base and subclass resolves to the base owner" do
    # Base and leaf both emit the SAME custom token, and the leaf's constant name
    # IS that token, so Rails constantizes the token to the narrower subclass.
    # Reverse resolution must still return the registered base (base_class), or a
    # subclass STI predicate would mislabel sibling rows as inert.
    base = Class.new(ApplicationRecord) do
      self.table_name = "folders"
      def self.polymorphic_name = "TokenStiLeaf"
    end
    Object.send(:const_set, "TokenStiBase", base)
    leaf = Class.new(base) do
      def self.polymorphic_name = "TokenStiLeaf"
    end
    Object.send(:const_set, "TokenStiLeaf", leaf)
    CurrentScope.rebuild_polymorphic_registry!

    assert_equal TokenStiBase, CurrentScope.polymorphic_class("TokenStiLeaf")
    assert_equal TokenStiBase, "TokenStiLeaf".constantize.base_class,
                 "precondition: the token constantizes to the leaf, whose base is TokenStiBase"
  ensure
    Object.send(:remove_const, :TokenStiLeaf) if defined?(TokenStiLeaf)
    Object.send(:remove_const, :TokenStiBase) if defined?(TokenStiBase)
    CurrentScope.rebuild_polymorphic_registry!
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

    # Precondition: the polymorphic resource association is unloaded (custom token
    # Rails cannot reverse through the association reader), so resolution has to go
    # through find_by against the registry-resolved class, not association.target.
    assert_not grant.association(:resource).loaded?
    assert_equal doc, grant.current_scope_resolved_record("resource")
    # The resolved record is cached onto the association, so a second resolve of
    # the same side on this row does not re-query.
    assert grant.association(:resource).loaded?
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

  test "polymorphic_class_names writer rejects String/Symbol duplicate keys" do
    config = CurrentScope::Configuration.new
    # :token_docs and "token_docs" normalize to one key; without this guard the
    # second silently overwrites the first, so a token could name two classes
    # without the duplicate-token error ever firing.
    error = assert_raises(CurrentScope::ConfigurationError) do
      config.polymorphic_class_names = { token_docs: "TokenDocument", "token_docs" => "Folder" }
    end
    assert_match(/String vs Symbol/, error.message)
    assert_equal({}, config.polymorphic_class_names)
  end

  test "config mapping a token the class does not store is refused" do
    CurrentScope.config.polymorphic_class_names = { "old_token" => "User" }
    error = assert_raises(CurrentScope::ConfigurationError) do
      CurrentScope.rebuild_polymorphic_registry!
    end
    assert_match(/old_token/, error.message)
    assert_match(/User/, error.message)

    CurrentScope.config.polymorphic_class_names = {}
    CurrentScope.rebuild_polymorphic_registry!
    assert_nil CurrentScope.polymorphic_class("old_token")
  ensure
    CurrentScope.config.polymorphic_class_names = {}
    CurrentScope.rebuild_polymorphic_registry!
  end

  test "config naming an unknown class raises" do
    CurrentScope.config.polymorphic_class_names = { "token_docs" => "NoSuchDocument" }
    error = assert_raises(CurrentScope::ConfigurationError) do
      CurrentScope.rebuild_polymorphic_registry!
    end
    assert_match(/NoSuchDocument/, error.message)
  ensure
    CurrentScope.config.polymorphic_class_names = {}
    CurrentScope.rebuild_polymorphic_registry!
  end

  test "a custom token on an STI base does not collide with siblings" do
    original = Document.method(:polymorphic_name)
    Document.define_singleton_method(:polymorphic_name) { "docs" }
    Invoice
    Receipt

    assert_nothing_raised { CurrentScope.rebuild_polymorphic_registry! }
    assert_equal Document, CurrentScope.polymorphic_class("docs")
  ensure
    Document.define_singleton_method(:polymorphic_name, original)
    CurrentScope.rebuild_polymorphic_registry!
  end

  test "a custom-token class loaded after rebuild still reverse-resolves" do
    LateTokenRecord
    CurrentScope.rebuild_polymorphic_registry!
    assert_equal LateTokenRecord, CurrentScope.polymorphic_class("late_tokens")
  end

  test "a custom token that matches another class's default token raises" do
    original = Folder.method(:polymorphic_name)
    Folder.define_singleton_method(:polymorphic_name) { "User" }

    error = assert_raises(CurrentScope::ConfigurationError) do
      CurrentScope.rebuild_polymorphic_registry!
    end
    assert_match(/User/, error.message)
    assert_match(/Folder/, error.message)
  ensure
    Folder.define_singleton_method(:polymorphic_name, original)
    CurrentScope.rebuild_polymorphic_registry!
  end

  test "a shortened token still registers when another constant has that name" do
    Object.const_set(:TokenInvoice, Class.new) unless Object.const_defined?(:TokenInvoice, false)
    BillingNs::TokenInvoice
    CurrentScope.rebuild_polymorphic_registry!

    assert_equal BillingNs::TokenInvoice, CurrentScope.polymorphic_class("TokenInvoice")
  ensure
    Object.send(:remove_const, :TokenInvoice) if Object.const_defined?(:TokenInvoice, false) &&
                                                 !TokenInvoice.respond_to?(:polymorphic_name)
    CurrentScope.rebuild_polymorphic_registry!
  end

  test "a shortened namespaced token reverse-resolves when Rails cannot" do
    BillingNs::TokenInvoice
    CurrentScope.rebuild_polymorphic_registry!
    assert_equal "TokenInvoice", BillingNs::TokenInvoice.polymorphic_name
    assert_equal BillingNs::TokenInvoice, CurrentScope.polymorphic_class("TokenInvoice")
  end

  test "shortened STI sibling tokens do not raise" do
    original = Document.store_full_class_name
    Document.store_full_class_name = false
    Invoice
    Receipt

    assert_nothing_raised { CurrentScope.rebuild_polymorphic_registry! }
    assert_equal "Document", Invoice.polymorphic_name
    assert_equal "Document", Receipt.polymorphic_name
    # Default tokens now live in the map (#163). The old nil pin was a size
    # optimization, not a collision check: Invoice and Receipt share Document
    # as base_class, so claim! accepts both.
    assert_equal Document, CurrentScope.polymorphic_registry["Document"]
  ensure
    Document.store_full_class_name = original
    CurrentScope.rebuild_polymorphic_registry!
  end

  test "the rebuilt registry is frozen" do
    CurrentScope.rebuild_polymorphic_registry!
    assert CurrentScope.polymorphic_registry.frozen?
    assert_raises(FrozenError) { CurrentScope.polymorphic_registry["x"] = Folder }
  end

  test "preload_resolvable_resources! labels a mapped custom-token grant" do
    user = User.create!(name: "PreloadHolder")
    doc = TokenDocument.create!(name: "PreloadDoc")
    role = CurrentScope::Role.create!(name: "PreloadViewer")
    grant = CurrentScope::ScopedRoleAssignment.create!(subject: user, role: role, resource: doc)
    grant = CurrentScope::ScopedRoleAssignment.find(grant.id)

    CurrentScope::ScopedRoleAssignment.preload_resolvable_resources!([ grant ])

    assert grant.association(:resource).loaded?
    assert_equal doc, grant.resource
  end
end
