# A NAMESPACED SoD controller — the shape a real app usually approves things in.
# Its path is "admin/reports" but it acts on Report records, whose route_key is
# "reports", and the resolver derives the break-glass key from the RECORD
# (reports#bypass_sod), never from the controller path. So the catalog must
# inject the bypass key under the last path segment; keying it off the whole
# path would produce admin/reports#bypass_sod and leave break-glass ungrantable
# here. Exists to pin that.
module Admin
  class ReportsController < ApplicationController
    include CurrentScope::Guard

    def approve
      render plain: "approved #{report.title}"
    end

    private

    def report
      @report ||= Report.find(params[:id])
    end

    def current_scope_record
      report if request.path_parameters[:id]
    end
  end
end
