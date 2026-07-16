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

  # The guide is only useful if the person retrofitting can actually reach it.
  # These tests are about REACHABILITY, not existence — the first version checked
  # that the file was in this repo, which is the one place the reader isn't.
  # (#64 review, qodo/devin)

  test "the guide is pointed at by an absolute URL, not a path the reader cannot resolve" do
    controller("application_controller.rb")
    controller("reports_controller.rb")

    output = run_generator

    assert_match %r{https://github\.com/\S+/adopting-in-an-existing-app\.md}, output
    assert_no_match(/(?<!blob\/main\/)docs\/guides\/adopting-in-an-existing-app\.md\s*$/, output,
                    "a bare repo-relative path resolves against the HOST's app, where it does not " \
                    "exist — and the gemspec ships no docs/, so it is not in the installed gem either")
  end

  # The URL is a promise about a file in THIS repo. If the guide is renamed and
  # the constant isn't, the generator sends every installing host to a 404 and
  # nothing else in the suite would notice.
  test "the URL the generator prints names a file that exists here" do
    path = CurrentScope::Generators::InstallGenerator::GUIDE_PATH
    guide = File.expand_path("../../#{path}", __dir__)

    assert File.exist?(guide), "GUIDE_PATH points at #{path}, which does not exist"
    assert_includes CurrentScope::Generators::InstallGenerator::GUIDE_URL, path,
                    "the URL must be built from GUIDE_PATH, or the two drift and only the URL lies"
  end

  # It is retrofit advice, and existing_app? already tells us who is retrofitting.
  # A fresh `rails new` has nothing to retrofit and shouldn't be handed reading.
  test "a fresh app is not pointed at the retrofit guide" do
    controller("application_controller.rb")

    output = run_generator

    assert_no_match(/adopting-in-an-existing-app/, output)
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
