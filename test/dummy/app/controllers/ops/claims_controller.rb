# Namespaced SoD-only controller whose last path segment ("claims") has no
# top-level routes. With break-glass on, the catalog injects claims#bypass_sod
# as a synthetic row with no routed actions — used by #43 grid tests.
module Ops
  class ClaimsController < ApplicationController
    include CurrentScope::Guard

    def approve
      head :ok
    end

    private

    def current_scope_record
      # No real model needed for the catalog/grid probe.
      nil
    end
  end
end
