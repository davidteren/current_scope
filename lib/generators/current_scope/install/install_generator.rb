module CurrentScope
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      def copy_initializer
        template "initializer.rb", "config/initializers/current_scope.rb"
      end

      def mount_engine
        route 'mount CurrentScope::Engine => "/current_scope"'
      end

      def show_next_steps
        # Keep this list in lockstep with README Installation and
        # docs/site/quickstart.md (#25). Three paths must not disagree.
        say <<~NEXT

          CurrentScope installed. Next steps (canonical quickstart):

            1. bin/rails current_scope:install:migrations && bin/rails db:migrate
            2. Include the concerns in ApplicationController (Context first):
                 include CurrentScope::Context
                 include CurrentScope::Guard
            3. Skip the gate on sign-in / public endpoints (or nobody can log in):
                 class SessionsController < ApplicationController
                   skip_before_action :current_scope_check!
                 end
                 Skipping leaves that controller ungated by CurrentScope —
                 use your own auth there (see docs/SECURITY-CHECKLIST.md).
            4. Bootstrap the first admin (Member starts with zero permissions):
                 bin/rails current_scope:grant SUBJECT_ID=YOUR_USER_ID
                 # or: CurrentScope.grant!(User.first)  # upserts Owner; not RoleAssignment.create!
            5. Manage roles at /current_scope (full-access subjects only).
            6. A denial is 403 with X-Current-Scope-Reason (no_grant, sod_veto, …).

            Full guide: https://davidteren.github.io/current_scope/quickstart.html

        NEXT

        say_retrofit_warning if existing_app?
      end

      # An ABSOLUTE URL, not a repo-relative path. This prints in the HOST's
      # terminal, in the HOST's app directory: "docs/guides/..." would resolve
      # against their app, where it does not exist — and the gemspec ships only
      # {app,config,db,lib} + README, so it is not in the installed gem either.
      # Shipping docs/ wouldn't fix it (nobody reads docs out of a gem's install
      # dir); a URL is the only form that resolves from where the reader is
      # standing, and terminals make it clickable. (#64 review, qodo)
      #
      # Points at blob/main deliberately: the guide does not exist at the last
      # release tag (it landed after v0.2.0), so a version-pinned URL would 404
      # today. Revisit pinning to "blob/v#{VERSION}" at the next release, when a
      # tag containing the guide exists. (#71 review, qodo)
      GUIDE_PATH = "docs/guides/adopting-in-an-existing-app.md".freeze
      GUIDE_URL = "https://github.com/davidteren/current_scope/blob/main/#{GUIDE_PATH}".freeze

      private

        # Adding a fail-closed gate to an app that already has controllers means
        # every one of them starts denying: nothing is granted yet. That is the
        # engine working, but it reads as "the gem broke my app" — and it lands
        # AFTER step 2 above, when the suite is already red and the person is
        # already reaching for git revert. Say it before that happens.
        def say_retrofit_warning
          say <<~RETROFIT, :yellow
            Heads up — this app already has controllers.

            Step 2 mounts a FAIL-CLOSED gate: anything not granted is denied. No
            grants exist yet, so your controller specs will go red and your users
            will get 403s. Nothing is misconfigured when that happens; it is the
            gate doing its job on an app that hasn't been granted anything.

            To retrofit incrementally instead, set this before step 2:

                config.enforcement = :report   # config/initializers/current_scope.rb

            The gate then logs what it WOULD deny and lets it through. Run your
            suite, then read the gaps back as a starter role grid:

                bin/rails current_scope:report

            Seed the roles it names, watch it empty out, then flip to :enforce.
            One line back at any point.

            The full retrofit guide — callback ordering vs. your authentication,
            the Devise recipe, the skip_before_action fail-open trap, and a
            rollout ladder:

                #{GUIDE_URL}

          RETROFIT
        end

        # ponytail: "does this app have controllers of its own" — the closed set
        # is app/controllers/*.rb minus the one Rails generates for every app.
        # A fresh `rails new` has only application_controller.rb, so it gets the
        # clean install message; anything more means a real app is being
        # retrofitted. Wrong guess costs a paragraph of advice, not correctness.
        def existing_app?
          controllers = Dir.glob(File.join(destination_root, "app/controllers/**/*_controller.rb"))
          controllers.reject { |f| File.basename(f) == "application_controller.rb" }.any?
        end
    end
  end
end
