CurrentScope.configure do |config|
  # Exercised by GuardTest: an excluded controller that still includes the
  # gate is a misconfiguration Guard must surface loudly.
  config.excluded_controllers += [ %r{\Awebhooks\z} ]
end
