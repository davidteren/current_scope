source "https://rubygems.org"

# Specify your gem's dependencies in current_scope.gemspec.
gemspec

gem "puma"

gem "sqlite3"

gem "propshaft"

# Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
gem "rubocop-rails-omakase", require: false

# System tests: render the mounted UI in a real (headless) browser so template
# errors and layout regressions are caught, not just structure. Cuprite drives
# an already-installed Chrome over CDP — no separate driver binary.
group :test do
  gem "capybara"
  gem "cuprite"
  # Coverage signal in CI (T6 / #114). Opt out with COVERAGE=0.
  gem "simplecov", require: false
end

# Start debugger with binding.b [https://github.com/ruby/debug]
# gem "debug", ">= 1.0.0"
