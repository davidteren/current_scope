module CurrentScope
  # Read-only view of the append-only audit ledger. Inherits the full-access
  # gate and mutation guard from ApplicationController; there is no write path.
  class EventsController < ApplicationController
    PER_PAGE = 50

    def index
      @page = [ params[:page].to_i, 1 ].max
      scope = Event.order(id: :desc)
      @events = scope.limit(PER_PAGE).offset((@page - 1) * PER_PAGE)
      @has_next_page = scope.offset(@page * PER_PAGE).exists?
    end
  end
end
