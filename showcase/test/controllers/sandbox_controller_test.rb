require "test_helper"

class SandboxControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  # The limiter uses a dedicated in-process store (a real counter, unlike the
  # null app cache), so clear it between tests to isolate the burst count.
  setup { SandboxController::RATE_LIMIT_STORE.clear }

  test "the reset control enqueues SandboxResetJob and is reachable by the Visitor" do
    assert_enqueued_with(job: SandboxResetJob) do
      post sandbox_reset_path
    end
    assert_redirected_to root_path
    follow_redirect!
    assert_select "p.notice", /Resetting the sandbox/
  end

  test "a rapid burst of resets is rate-limited" do
    5.times { post sandbox_reset_path } # to: 5 within 1.minute

    assert_no_enqueued_jobs only: SandboxResetJob do
      post sandbox_reset_path # the 6th is over the limit
    end
    assert_redirected_to root_path
    follow_redirect!
    assert_select "p.alert", /try again/i
  end
end
