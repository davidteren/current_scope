require "test_helper"

class GemspecTest < ActiveSupport::TestCase
  SPEC = Gem::Specification.load(File.expand_path("../current_scope.gemspec", __dir__))

  test "declares a Rails 8+ floor — matching the params.expect API the engine uses" do
    rails = SPEC.dependencies.find { |d| d.name == "rails" }
    assert rails, "rails dependency is missing from the gemspec"

    reqs = rails.requirement.as_list
    assert_includes reqs, ">= 8.0", "the Rails floor must be >= 8.0 (params.expect is a Rails 8 API)"
    assert_includes reqs, "< 9", "the Rails dependency should carry an upper bound"

    # Guard against a regression to the old false ">= 7.1" claim.
    assert_not_includes reqs, ">= 7.1"
  end
end
