require "test_helper"

# #142: optional class-level current_scope_model. The gate still calls the
# instance method, so the macro defines that method too. A controller that
# never calls the macro keeps today's instance-method shape.
class CurrentScopeModelDeclarationTest < ActiveSupport::TestCase
  test "a subclass inherits the model until it calls the macro again" do
    parent = controller_class
    parent.current_scope_model Report

    child = Class.new(parent)

    assert_equal Report, child.current_scope_declared_model
    assert_equal Report, child.new.send(:current_scope_model)
    assert_equal parent.current_scope_model_macro_method,
                 child.instance_method(:current_scope_model),
                 "an inherited method is the macro's method, not a hand-written one"

    child.current_scope_model Invoice

    assert_equal Invoice, child.current_scope_declared_model
    assert_equal Invoice, child.new.send(:current_scope_model)
    assert_equal Report, parent.current_scope_declared_model
    assert_equal Report, parent.new.send(:current_scope_model)
  end

  test "an instance returns the declared class" do
    klass = controller_class
    klass.current_scope_model Report

    assert_equal Report, klass.new.send(:current_scope_model)
    assert_includes klass.private_instance_methods, :current_scope_model
    assert_equal klass.current_scope_model_macro_method, klass.instance_method(:current_scope_model)
  end

  test "a controller that never calls the macro has no class attribute set" do
    klass = controller_class

    assert_nil klass.current_scope_declared_model
    assert_nil klass.current_scope_model_macro_method
    refute klass.private_method_defined?(:current_scope_model)
    refute klass.method_defined?(:current_scope_model)
  end

  # Macro, then a later def: the request uses the def. Def, then the macro:
  # define_method replaces the def, so the request uses the macro's method.
  test "a later instance method replaces the method the macro defined" do
    klass = controller_class
    klass.current_scope_model Report
    klass.class_eval do
      private def current_scope_model = Invoice
    end

    assert_equal Report, klass.current_scope_declared_model
    assert_equal Invoice, klass.new.send(:current_scope_model)
    refute_equal klass.current_scope_model_macro_method, klass.instance_method(:current_scope_model)
  end

  test "the macro replaces an earlier instance method and does not leave it in place" do
    klass = controller_class
    klass.class_eval do
      private def current_scope_model = Invoice
    end
    klass.current_scope_model Report

    assert_equal Report, klass.new.send(:current_scope_model)
    assert_equal klass.current_scope_model_macro_method, klass.instance_method(:current_scope_model)
  end

  private

  def controller_class
    Class.new(ActionController::Base) do
      include CurrentScope::Guard
    end
  end
end
