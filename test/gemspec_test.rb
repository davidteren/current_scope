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
    docs = "https://davidteren.github.io/current_scope/"
    repo = "https://github.com/davidteren/current_scope"

    assert_equal "true", meta["rubygems_mfa_required"]
    assert_equal docs, SPEC.homepage
    assert_equal docs, meta["documentation_uri"]
    assert_equal repo, meta["source_code_uri"]
    assert_equal "#{repo}/issues", meta["bug_tracker_uri"]
    assert_equal "#{repo}/blob/main/CHANGELOG.md", meta["changelog_uri"]
    # The dup-uri gem-build warning fires when homepage_uri == source_code_uri.
    assert_not_equal SPEC.homepage, meta["source_code_uri"]
  end
end
