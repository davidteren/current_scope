require "test_helper"
require "capybara/rails"
require "capybara/cuprite"

# Headless Chrome over CDP (cuprite) — renders the mounted management UI for real,
# so a template error or broken layout is caught, not just DOM structure.
Capybara.register_driver(:cuprite_headless) do |app|
  Capybara::Cuprite::Driver.new(
    app,
    window_size: [ 1280, 900 ],
    headless: true,
    process_timeout: 30,
    browser_options: { "no-sandbox" => nil }
  )
end

Capybara.default_max_wait_time = 5
Capybara.server = :puma, { Silent: true }

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :cuprite_headless

  SHOTS = File.expand_path("../tmp/screenshots", __dir__)

  # The dummy authenticates from an X-User-Id header; set it on the browser
  # session so the engine's require_full_access! gate sees the signed-in owner.
  def sign_in(user)
    page.driver.add_headers("X-User-Id" => user.id.to_s)
  end

  # Save a screenshot under tmp/screenshots for visual inspection. Viewport by
  # default (what the user actually sees — full-page capture distorts sticky
  # positioning); pass full: true for the whole scroll height.
  def shot(name, full: false)
    FileUtils.mkdir_p(SHOTS)
    path = File.join(SHOTS, "#{name}.png")
    page.save_screenshot(path, full: full)
    path
  end

  # A page that rendered without a Rails error page.
  def assert_rendered
    assert_equal 200, page.status_code, "expected a 200, got #{page.status_code} — likely a template error"
    assert_no_text "Template::Error"
    assert_no_text "NoMethodError"
  end
end
