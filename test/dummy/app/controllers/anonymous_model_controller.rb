# A current_scope_model that returns a REAL ActiveRecord class with no name.
# Class#name is nil until the class is assigned to a constant, so this hook is
# usable by the gate and unnameable by the ledger. Exists so the guard that
# refuses to record a nameless model has a request-level shape (#196 review):
# without it the row would store model: nil, which the report reads as "the gate
# had no model here" and re-checks on the stricter question.
class AnonymousModelController < ApplicationController
  include CurrentScope::Guard

  def self.anonymous_model
    # NOT assigned to a constant: that is what would give it a name. And NOT a
    # subclass of an application model either — that would put an anonymous STI
    # descendant into the dummy app and change what other tests see.
    @anonymous_model ||= Class.new
  end

  def index
    render plain: "anonymous"
  end

  private

  def current_scope_record = nil
  def current_scope_model = self.class.anonymous_model
end
