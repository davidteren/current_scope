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
  # Used directly by test/system/docs_site_reveal_test.rb, which drives the
  # static docs page over file:// with no app server. It arrives through cuprite
  # anyway, but a file that requires it should say so: otherwise a driver change
  # in cuprite would surface as a missing gem rather than as what it is.
  gem "ferrum"
  # #151 widened the polymorphic id columns to string, and adapters disagree about
  # comparing a string column to an integer one: SQLite coerces silently, MySQL
  # coerces with an index cost, PostgreSQL raises. A SQLite-only suite cannot see
  # that, so the suite runs against all three. Containers come from bin/db (Docker).
  gem "pg", require: false
  gem "trilogy", require: false
  # Coverage signal in CI (T6 / #114). Opt out with COVERAGE=0.
  gem "simplecov", require: false
end

# Start debugger with binding.b [https://github.com/ruby/debug]
# gem "debug", ">= 1.0.0"
