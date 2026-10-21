# The normal engine boot does not load browser-test helpers. Load the source
# before Mutineer's surgical strategy redefines its methods in each child.
require_relative "mutineer_boot"
require_relative "system/support/headless_chrome"
