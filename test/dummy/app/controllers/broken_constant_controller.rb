# A controller whose OWN BODY is broken: constantizing it triggers the Zeitwerk
# load, the body raises NameError, and that error must PROPAGATE out of
# GatingReflection — a blanket `rescue NameError` would silently report this
# broken controller as gated. Rails' controller_class_for tells the two apart
# by missing_name: here it is BrokenConstantController::NOPE_NOT_DEFINED, not
# the controller constant itself, so it re-raises instead of wrapping in
# MissingController. Deliberately NOT routed — a route would put it in the
# permission catalog and every grid test's fixtures.
#
# Excluded from EAGER loading (see config/application.rb) but still
# autoloadable: eager_load is on in CI, and this file would otherwise explode
# the whole suite at boot instead of exactly one constantize.
class BrokenConstantController < ApplicationController
  NOPE_NOT_DEFINED
end
