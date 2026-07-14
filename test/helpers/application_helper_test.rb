require "test_helper"

module CurrentScope
  class ApplicationHelperTest < ActionView::TestCase
    include CurrentScope::ApplicationHelper

    setup { @original_label = CurrentScope.config.subject_label }
    teardown { CurrentScope.config.subject_label = @original_label }

    test "a blank/whitespace email falls through to the next identifier, not an empty label" do
      CurrentScope.config.subject_label = nil # exercise the default chain
      subject = Struct.new(:email, :name).new("   ", "Fallback Person")
      assert_equal "Fallback Person", current_scope_subject_label(subject)
    end

    test "a configured label that resolves blank falls back to the default chain" do
      CurrentScope.config.subject_label = ->(_) { "" }
      subject = Struct.new(:name).new("Named Person")
      assert_equal "Named Person", current_scope_subject_label(subject)
    end
  end
end
