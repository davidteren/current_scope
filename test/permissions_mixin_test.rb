require "test_helper"
require "current_scope/test_helpers"

# A stand-in for any PORO/component that mixes in the portable helper.
class FakeComponent
  include CurrentScope::Permissions
end

class PermissionsMixinTest < ActiveSupport::TestCase
  include CurrentScope::TestHelpers

  setup do
    @alice = User.create!(name: "Alice")
    @report = Report.create!(title: "Q3", requested_by: @alice)
    reviewer = CurrentScope::Role.create!(name: "Reviewer")
    reviewer.role_permissions.create!(permission_key: "reports#show")
    CurrentScope::RoleAssignment.create!(subject: @alice, role: reviewer)
    # SoD is opt-in (empty by default); one test here asserts the :either veto.
    @original_sod_actions = CurrentScope.config.sod_actions
    CurrentScope.config.sod_actions = %w[approve]
  end

  teardown do
    CurrentScope.config.sod_actions = @original_sod_actions
  end

  test "allowed_to? reads the ambient subject — no threading required" do
    component = FakeComponent.new

    with_current_user(@alice) do
      assert component.allowed_to?(:show, @report)
      assert_not component.allowed_to?(:destroy, @report)
    end
  end

  test "no ambient subject means denied" do
    assert_not FakeComponent.new.allowed_to?(:show, @report)
  end

  test "under impersonation, allowed_to? and the resolver agree on an actor-initiated record" do
    admin = User.create!(name: "Admin")
    report = Report.create!(title: "Q9", requested_by: admin)   # initiated by the actor
    # @alice already holds an org-wide role (setup); widen it rather than adding
    # a second assignment (one org-wide role per subject).
    CurrentScope::RoleAssignment.find_by(subject: @alice).role
                                .role_permissions.create!(permission_key: "reports#approve")

    # View helper reads the ambient actor and honours the SoD :either veto...
    with_current_user(@alice, actor: admin) do   # admin acts as @alice
      assert_not FakeComponent.new.allowed_to?(:approve, report)
    end

    # ...and the resolver the Guard consults reaches the same verdict + reason.
    allowed, reason = CurrentScope::Resolver.new.decide(
      subject: @alice, permission: "reports#approve", record: report, actor: admin
    )
    assert_not allowed
    assert_equal :sod_veto, reason
  end

  test "with_current_user restores the previous subject" do
    with_current_user(@alice) { nil }
    assert_nil CurrentScope::Current.user
  end

  # --- #50 U6: the advisory path binds the record-less gate by the ambient
  # collection model, exactly like the gate, so a view never disagrees. ---

  # A component that answers controller_path, standing in for a view rendered
  # inside a controller. The Guard stashes the ambient model + its path; this
  # simulates being rendered from that same controller (path matches).
  class ViewComponent
    include CurrentScope::Permissions
    def initialize(path) = @path = path
    def controller_path = @path
  end

  def with_ambient_model(type, path)
    CurrentScope::Current.collection_model = type
    CurrentScope::Current.collection_model_path = path
    yield
  ensure
    CurrentScope::Current.collection_model = nil
    CurrentScope::Current.collection_model_path = nil
  end

  test "a bare allowed_to?(:index) on the request's own controller uses the ambient type" do
    editor = CurrentScope::Role.create!(name: "Editor")
    editor.role_permissions.create!(permission_key: "reports#index")
    CurrentScope::ScopedRoleAssignment.create!(subject: @alice, role: editor, resource: @report)

    with_current_user(@alice) do
      with_ambient_model(Report, "reports") do
        assert ViewComponent.new("reports").allowed_to?(:index),
          "the view binds by the ambient Report type and agrees with the gate"
      end
    end
  end

  test "a cross-controller allowed_to? does NOT borrow the ambient type (KTD-6)" do
    editor = CurrentScope::Role.create!(name: "Editor")
    editor.role_permissions.create!(permission_key: "reports#index")
    CurrentScope::ScopedRoleAssignment.create!(subject: @alice, role: editor, resource: @report)

    with_current_user(@alice) do
      # Ambient is Project (a projects request), asked about reports.
      with_ambient_model(Project, "projects") do
        assert_not ViewComponent.new("projects").allowed_to?(:index, controller: "reports"),
          "the projects request's Project type must not answer a reports question"
      end
    end
  end

  test "the class form binds from its argument, ignoring the ambient type (R5)" do
    editor = CurrentScope::Role.create!(name: "Editor")
    editor.role_permissions.create!(permission_key: "documents#index")
    invoice = Invoice.create!(title: "INV-1")
    CurrentScope::ScopedRoleAssignment.create!(subject: @alice, role: editor, resource: invoice)

    with_current_user(@alice) do
      # Report-ambient request, but the class form names Document.
      with_ambient_model(Report, "reports") do
        assert ViewComponent.new("reports").allowed_to?(:index, Document),
          "allowed_to?(:index, Document) binds from Document, not the ambient Report"
      end
    end
  end

  test "outside a request the ambient is nil, so a bare collection form fails closed" do
    editor = CurrentScope::Role.create!(name: "Editor")
    editor.role_permissions.create!(permission_key: "reports#index")
    CurrentScope::ScopedRoleAssignment.create!(subject: @alice, role: editor, resource: @report)

    with_current_user(@alice) do
      # A PORO with no controller_path and no ambient model set.
      assert_not FakeComponent.new.allowed_to?(:index, controller: "reports"),
        "no ambient type ⇒ the record-less branch does not fire"
    end
  end

  test "R11: an org-wide grant's bare allowed_to?(:index) is unchanged by the ambient" do
    CurrentScope::RoleAssignment.find_by(subject: @alice).role
                                .role_permissions.create!(permission_key: "reports#index")

    with_current_user(@alice) do
      with_ambient_model(Report, "reports") do
        assert ViewComponent.new("reports").allowed_to?(:index)
      end
      # Same answer with no ambient — org grants never read the model.
      assert ViewComponent.new("reports").allowed_to?(:index)
    end
  end
end
