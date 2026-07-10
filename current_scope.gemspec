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
  spec.add_dependency "rails", ">= 7.1"
end
