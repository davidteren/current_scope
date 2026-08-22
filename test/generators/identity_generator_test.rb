require "test_helper"
require "rails/generators/test_case"
require "generators/current_scope/identity/identity_generator"

class IdentityGeneratorTest < Rails::Generators::TestCase
  tests CurrentScope::Generators::IdentityGenerator
  destination File.expand_path("../tmp/generator", __dir__)

  setup { prepare_destination }

  test "writes a stub resolver stamped with the placeholder mark" do
    output = run_generator

    assert_file "app/models/current_scope_subject_identity.rb" do |content|
      assert_match "current_scope_placeholder", content
      assert_match "def identify(subject)", content
      assert_match "def resolve(key)", content
      assert_match "def create_placeholder!(key)", content
      assert_match "subject_label", content
    end

    assert_match "not config.subject_label", output
    assert_match "WRITE=1", output
    assert_match "PLACEHOLDER=1", output
  end
end
