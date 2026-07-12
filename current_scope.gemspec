require_relative "lib/current_scope/version"

Gem::Specification.new do |spec|
  spec.name        = "current_scope"
  spec.version     = CurrentScope::VERSION
  spec.authors     = [ "David Teren" ]
  spec.email       = [ "dteren@gmail.com" ]
  spec.homepage    = "https://github.com/davidteren/current_scope"
  spec.summary     = "Data-driven authorization for Rails with an ambient current-user context."
  spec.description = "A mountable Rails engine for authorization: permissions auto-derived " \
                     "from controller actions, roles as editable data, per-record scoped roles, " \
                     "a separation-of-duties veto, and an ambient authorization context that " \
                     "makes allowed_to? work identically in controllers, views, and components."
  spec.license     = "MIT"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  end

  spec.required_ruby_version = ">= 3.2"
  # Floor is 8.1, proven by running the suite against it (A9). The management UI
  # relies on `params.expect` ARRAY semantics that changed between 8.0 and 8.1
  # (on 8.0 the permission_keys array comes back empty), so 8.0 is not actually
  # supported despite params.expect existing there. The earlier ">= 7.1" was a
  # false claim that would NoMethodError on 7.x. Migration version brackets stay
  # at [7.1] deliberately: they pin generation-time schema defaults, not the
  # gem's minimum Rails, and current_scope_events is a frozen schema.
  spec.add_dependency "rails", ">= 8.1", "< 9"
end
