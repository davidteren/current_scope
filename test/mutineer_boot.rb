# frozen_string_literal: true

# Boot file for Mutineer (`--boot` / .mutineer.yml). The dummy app's
# environment is the engine's Rails entry point, but it does not put `test/`
# on $LOAD_PATH. Every engine test starts with `require "test_helper"`, which
# then fails after a plain `test/dummy/config/environment` boot and Mutineer
# reports the unmutated suite as red.
#
# COVERAGE=0 is required: test_helper would otherwise start SimpleCov, which
# fights Mutineer's Coverage map and, under CI=1, applies the 95/80 floor.

ENV["RAILS_ENV"] ||= "test"
ENV["COVERAGE"] = "0"

test_dir = __dir__
$LOAD_PATH.unshift(test_dir) unless $LOAD_PATH.include?(test_dir)

require_relative "dummy/config/environment"
