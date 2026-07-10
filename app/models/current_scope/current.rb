module CurrentScope
  # The ambient authorization context. Request- and job-scoped: Rails resets
  # CurrentAttributes around every unit of execution, so the subject can never
  # leak between requests, jobs, or test examples.
  class Current < ActiveSupport::CurrentAttributes
    attribute :user
  end
end
