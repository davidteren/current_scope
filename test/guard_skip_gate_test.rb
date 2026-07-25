require "test_helper"

# #76 — current_scope_skip_gate!(reason:) records intent and performs the skip.
class GuardSkipGateTest < ActiveSupport::TestCase
  test "the macro records a whole-controller reason and removes the gate callback" do
    assert_equal "public health-check endpoint", DeclaredSkipController.current_scope_gate_skip_reason
    assert CurrentScope::GatingReflection.new.ungated?("declared_skip")
    assert_equal "public health-check endpoint",
                 CurrentScope::GatingReflection.new.declared_skip_reason("declared_skip")
  end

  test "blank reason raises" do
    klass = Class.new(ApplicationController) do
      include CurrentScope::Guard
    end
    assert_raises(ArgumentError) { klass.current_scope_skip_gate!(reason: "  ") }
    assert_raises(ArgumentError) { klass.current_scope_skip_gate!(reason: nil) }
  end

  test "only: skips without claiming a whole-controller reason" do
    klass = Class.new(ApplicationController) do
      include CurrentScope::Guard
      current_scope_skip_gate!(reason: "index is public", only: :index)
    end
    assert_nil klass.current_scope_gate_skip_reason

    # Pin that only: is a real skip of the gate for that action, not a
    # reason-storing no-op. After only: :index the gate callback is still on
    # the chain (other actions remain gated); a whole-controller skip removes
    # it entirely (cubic P3).
    filters = klass._process_action_callbacks.select { |c|
      c.kind == :before && c.filter == :current_scope_check!
    }
    assert filters.any?, "only: :index must leave the gate on the chain for other actions"

    whole = Class.new(ApplicationController) do
      include CurrentScope::Guard
      current_scope_skip_gate!(reason: "public")
    end
    assert_empty whole._process_action_callbacks.select { |c|
      c.kind == :before && c.filter == :current_scope_check!
    }, "whole-controller skip must remove the gate callback"
  end

  test "a bare skip has no declared reason" do
    assert_nil WritesController.current_scope_gate_skip_reason
    assert_nil CurrentScope::GatingReflection.new.declared_skip_reason("writes")
  end
end
