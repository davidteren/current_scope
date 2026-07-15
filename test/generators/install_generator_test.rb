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
    assert_match "access.would_deny", output, "the warning has to say how to READ the gaps, not just enable the mode"
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
