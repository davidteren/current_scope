# A current_scope_model that returns a class the RESOLVER refuses: an anonymous
# plain class, which is neither an ActiveRecord model nor nameable. The gate
# could not have used it either, so the ledger records nil — knowledge, not a
# gap — and the report re-asks without a type, reproducing the gate's answer
# (#196 review).
class AnonymousModelController < ApplicationController
  include CurrentScope::Guard

  def self.anonymous_model
    # NOT assigned to a constant, and NOT descended from ActiveRecord::Base.
    # Either would give it a name or put an anonymous class into the descendant
    # trackers that PolymorphicRegistry and GrantDiagnosis walk, which changes
    # what other tests see: the first version of this fixture did exactly that
    # and failed GrantDiagnosisTest about one run in two.
    @anonymous_model ||= Class.new
  end

  def index
    render plain: "anonymous"
  end

  private

  def current_scope_record = nil
  def current_scope_model = self.class.anonymous_model
end
