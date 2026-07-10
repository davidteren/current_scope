require "test_helper"

class ScopeableTest < ActiveSupport::TestCase
  # Referencing the constants autoloads them; their `included` hook is the ONLY
  # thing that registers them, so a present registration proves the hook fired.
  setup { [ Widget, Gadget ] }

  test "including CurrentScope::Scopeable self-registers the model by name" do
    assert_includes CurrentScope.scopeable_resources, Widget
    assert_includes CurrentScope.scopeable_resources, Gadget
  end

  test "scopeable_resources lists the registered models sorted by name, deduped" do
    names = CurrentScope.scopeable_resources.map(&:name)

    assert_equal names.sort, names, "expected registered models sorted by name"
    assert_equal names.uniq, names, "expected no duplicate registrations"
    assert_includes names, "Gadget"
    assert_includes names, "Widget"
  end

  test "re-registering a model (a dev-mode reload) does not duplicate it" do
    CurrentScope.register_scopeable("Widget")

    assert_equal 1, CurrentScope.scopeable_resources.count { |model| model == Widget }
  end

  test "resetting then rebuilding the registry yields no duplicates" do
    snapshot = CurrentScope.scopeable_registry.dup

    CurrentScope.reset_scopeable_registry!
    assert_empty CurrentScope.scopeable_resources

    CurrentScope.register_scopeable("Widget")
    CurrentScope.register_scopeable("Widget")
    CurrentScope.register_scopeable("Gadget")

    assert_equal [ Gadget, Widget ], CurrentScope.scopeable_resources
  ensure
    CurrentScope.reset_scopeable_registry!
    snapshot.each { |name| CurrentScope.register_scopeable(name) }
  end

  test "default current_scope_label renders \"<Model> #<id>\"" do
    assert_equal "Widget #3", Widget.new(id: 3).current_scope_label
  end

  test "a model's own current_scope_label wins over the mixin default" do
    assert_equal "custom", Gadget.new(id: 3).current_scope_label
  end

  test "a non-scopeable model is absent from the registry yet still a valid scoped-role target" do
    project = Project.create!(name: "Untracked")

    assert_not_includes CurrentScope.scopeable_resources, Project

    assignment = CurrentScope::ScopedRoleAssignment.new(
      role: CurrentScope::Role.create!(name: "Reviewer"),
      subject: User.create!(name: "Subject"),
      resource: project
    )
    assert assignment.valid?, assignment.errors.full_messages.to_sentence
  end
end
