module CurrentScope
  # Read-only view of the append-only audit ledger. Inherits the full-access
  # gate and mutation guard from ApplicationController; there is no write path.
  class EventsController < ApplicationController
    def index
      # ponytail: hard cap, no pagination — matches the unpaginated subjects
      # page. Paginate when the ledger outgrows one screen.
      @events = Event.order(id: :desc).limit(200)
    end
  end
end
