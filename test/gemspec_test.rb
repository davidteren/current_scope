require "test_helper"

class GemspecTest < ActiveSupport::TestCase
  SPEC = Gem::Specification.load(File.expand_path("../current_scope.gemspec", __dir__))

  test "declares the tested Rails 8.1 floor with an upper bound" do
    rails = SPEC.dependencies.find { |d| d.name == "rails" }
    assert rails, "rails dependency is missing from the gemspec"

    reqs = rails.requirement.as_list
    # 8.1 is the proven floor (params.expect array semantics need it — A9), not 8.0.
    assert_includes reqs, ">= 8.1", "the Rails floor must be >= 8.1 (proven by the CI test job)"
    assert_includes reqs, "< 9", "the Rails dependency should carry an upper bound"

    # Guard against the old false ">= 7.1" claim.
    assert_not_includes reqs, ">= 7.1"
  end

  test "carries publish metadata and no duplicate homepage/source uri (warning-clean build)" do
    meta = SPEC.metadata
    assert_equal "true", meta["rubygems_mfa_required"]
    assert_match %r{/CHANGELOG\.md\z}, meta["changelog_uri"].to_s
    # The dup-uri gem-build warning fires when homepage_uri == source_code_uri;
    # we don't set source_code_uri, so that can't happen.
    assert_nil meta["source_code_uri"]
  end
end
