require "test_helper"
require "rails/generators/test_case"
require "generators/current_scope/install/install_generator"

# The install generator's advice is load-bearing for adoption (#37): a fail-closed
# gate added to an app that already has controllers denies everything until grants
# are seeded, and someone who reads that as "the gem broke my app" reverts instead
# of retrofitting. The warning that prevents that is only useful if it fires for
# the right app — so the routing is tested, not just the text.
class InstallGeneratorTest < Rails::Generators::TestCase
  tests CurrentScope::Generators::InstallGenerator
  destination File.expand_path("../tmp/generator", __dir__)

  setup do
    prepare_destination
    FileUtils.mkdir_p(File.join(destination_root, "config"))
    File.write(File.join(destination_root, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
  end

  def controller(path)
    full = File.join(destination_root, "app/controllers", path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, "class Whatever < ApplicationController; end\n")
  end

  test "the initializer documents report mode as the retrofit path" do
    run_generator

    assert_file "config/initializers/current_scope.rb" do |content|
      assert_match "config.enforcement", content
      assert_match ":report", content
      assert_match "fail-closed", content
    end
  end

  # The guide is only useful if the person retrofitting finds it, and install is
  # where they are. An unreferenced guide is a guide nobody reads. (#26)
  test "the next-steps message points at the adoption guide" do
    output = run_generator

    assert_match "docs/guides/adopting-in-an-existing-app.md", output
    assert_match(/already has auth/i, output, "say who it's for, or it reads as optional reading")
  end

  test "the adoption guide the generator names actually exists" do
    guide = File.expand_path("../../docs/guides/adopting-in-an-existing-app.md", __dir__)

    assert File.exist?(guide),
           "the generator tells every installing host to read this path — if it moves or is " \
           "renamed, that instruction becomes a 404 and nothing else would catch it"
  end

  test "a fresh app gets the clean install message and no retrofit warning" do
    controller("application_controller.rb") # what `rails new` leaves behind

    output = run_generator

    assert_match "CurrentScope installed", output
    assert_no_match(/already has controllers/, output,
                    "a new app has nothing to retrofit — the warning is noise there")
  end

  test "an app with its own controllers is warned before the gate goes on" do
    controller("application_controller.rb")
    controller("reports_controller.rb")

    output = run_generator

    assert_match "already has controllers", output
    assert_match "FAIL-CLOSED", output
    assert_match "config.enforcement = :report", output
    assert_match "current_scope:report", output,
                 "the warning has to say how to READ the gaps, not just how to enable the mode"
  end

  test "the warning finds namespaced controllers too" do
    controller("application_controller.rb")
    controller("admin/reports_controller.rb")

    assert_match "already has controllers", run_generator
  end

  test "an app with no controllers at all is not warned" do
    output = run_generator

    assert_no_match(/already has controllers/, output)
  end
end
