# Deliberately misconfigured: excluded from the catalog but still gated.
class WebhooksController < ApplicationController
  include CurrentScope::Guard

  def create
    head :ok
  end
end
