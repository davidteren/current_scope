module ApplicationHelper
  # The sandbox self-heals on a */15 schedule (config/recurring.yml). Cheap,
  # honest estimate of minutes to the next quarter-hour boundary — no scheduler
  # lookup, just the wall clock the cron fires against.
  def minutes_to_next_sandbox_reset
    15 - (Time.current.min % 15)
  end
end
