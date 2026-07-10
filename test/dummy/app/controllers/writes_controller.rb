# Exercises the mutation guard's skip mechanism. Both actions skip the
# permission check (current_scope_check!); only #unguarded also skips the
# mutation guard, standing in for a host's stop-impersonation / sign-out
# endpoint that must run while impersonating.
class WritesController < ApplicationController
  include CurrentScope::Guard

  skip_before_action :current_scope_check!, raise: false
  skip_before_action :current_scope_mutation_guard!, only: :unguarded

  def guarded
    head :ok
  end

  def unguarded
    head :ok
  end
end
