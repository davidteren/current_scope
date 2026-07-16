require "test_helper"

# PROBLEM FRAME (characterization — this class stays green forever, it pins the
# reality GatingReflection is built against): the naive presence check
#
#   _process_action_callbacks.any? { |c| c.kind == :before && c.filter == :current_scope_check! }
#
# answers "is this controller gated?" with YES for ConditionalSkipController —
# and a real request to its #index sails through UNGATED, because
# `skip_before_action ... only: :index` doesn't remove the callback, it leaves
# it in the chain wearing a condition. Presence does not mean the gate runs;
# absence is the only thing the chain states unconditionally. That inversion is
# why GatingReflection reports ungated? only on PROOF (callback absent) and
# refuses to guess about anything conditional.
class GatingReflectionProblemFrameTest < ActionDispatch::IntegrationTest
  test "the naive any? calls ConditionalSkip gated while its index really runs ungated" do
    naive_gated = ConditionalSkipController._process_action_callbacks.any? { |c|
      c.kind == :before && c.filter == :current_scope_check!
    }
    assert naive_gated, "precondition: the conditional skip leaves the callback IN the chain"

    # No X-User-Id header: an anonymous request. If the gate ran, this would be
    # a 403 (fail closed, like #show below) — it renders instead.
    get "/conditional_skip"
    assert_response :success
    assert_equal "conditional_skip#index", response.body
  end

  test "and the same controller's show really is gated — neither blanket answer is right" do
    get "/conditional_skip/show"
    assert_response :forbidden
  end
end

class GatingReflectionTest < ActiveSupport::TestCase
  setup { @reflection = CurrentScope::GatingReflection.new }

  test "a gated controller is not ungated" do
    assert_not @reflection.ungated?("reports")
  end

  test "a bare skip is proven ungated" do
    assert @reflection.ungated?("writes")
  end

  # The #62 fail-open at unit level: the child inherits the base's bare skip
  # and adds nothing, so the gate never runs there — provably, the callback is
  # absent from its chain.
  test "a child inheriting a bare skip is proven ungated" do
    assert @reflection.ungated?("inherited_skip_child")
  end

  # The adoption guide's mitigation for #62: re-asserting the gate in the
  # child puts the callback back in the chain.
  test "a child that re-asserts the gate is not ungated" do
    assert_not @reflection.ungated?("reasserted_gate")
  end

  # BareController never includes Guard at all. Same verdict as a bare skip:
  # the predicate reads the EFFECT (callback absent), not the cause.
  test "a controller that never included Guard is ungated" do
    assert @reflection.ungated?("bare")
  end

  # "admin/reports" must resolve Admin::ReportsController — Rails' own
  # path→class rule (KTD-2), not a hand-rolled camelize.
  test "a namespaced path resolves to its namespaced controller, which is gated" do
    assert_not @reflection.ungated?("admin/reports")
  end

  test "a conditional skip is never marked ungated — unprovable stays silent" do
    assert_not @reflection.ungated?("conditional_skip"),
               "ConditionalSkipController's #index really does run ungated — the " \
               "ProblemFrame tests above pin that the naive any? presence check says " \
               "'gated' here while an anonymous GET /conditional_skip renders fine. But " \
               "the callback is PRESENT in the chain, wearing a condition, and proving " \
               "which actions it skips means evaluating ActionFilter internals — which " \
               "this unit must never do (KTD-3). Present, conditional or not, means NOT " \
               "PROVEN ungated, so ungated? is false. If you are about to 'simplify' the " \
               "predicate into a per-action guess, this failure is the reason not to."
  end

  # The dummy routes `resources :orphaned` with no OrphanedController class
  # (documents now has a real controller — #50). A missing controller class.
  # A missing controller proves nothing about gating — false, silently.
  test "a routed path with no controller class is false, not an error" do
    assert_not @reflection.ungated?("orphaned")
  end

  # BrokenConstantController's own body raises NameError at load. That is a
  # broken controller, not a missing one — Rails' controller_class_for already
  # distinguishes the two by missing_name, and this unit must not flatten them
  # back together with a blanket `rescue NameError` (which would silently
  # report a broken controller as gated).
  test "a controller whose body raises NameError propagates it" do
    error = assert_raises(NameError) { @reflection.ungated?("broken_constant") }
    # Prove the re-raise branch was exercised: it is the body's constant that
    # is missing, not the controller's — so NOT a MissingController.
    assert_not_kind_of ActionDispatch::MissingController, error
    assert_equal :NOPE_NOT_DEFINED, error.name
  end

  # A bare ActionController::Metal (no AbstractController::Callbacks) has no
  # callbacks API at all — the gate PROVABLY cannot run there, and asking must
  # answer true rather than NoMethodError. (#79 review)
  test "a controller without the callbacks API is provably ungated, not an error" do
    metal = Class.new(ActionController::Metal)
    reflection = Class.new(CurrentScope::GatingReflection) {
      define_method(:controller_class_for) { |_| metal }
    }.new

    assert reflection.ungated?("metal_thing")
  end
end
