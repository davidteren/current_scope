# A NAMESPACED controller that never includes Guard: the badge's id/aria
# generation runs controller paths through parameterize, and "admin/unguarded"
# is the shape that breaks a naive separator choice. (#69 implementation
# review — the flat fixtures never exercised the namespaced ungated path.)
class Admin::UnguardedController < ApplicationController
  def index
    render plain: "admin/unguarded#index"
  end
end
