module Showcase
  # The demo's canonical dataset, extracted so BOTH db/seeds.rb and
  # SandboxResetJob plant the SAME ground truth.
  #
  # Idempotent AND restorative: every record is found by a stable natural key,
  # then its canonical mutable attributes are re-asserted (approval reset,
  # amounts, wording, grid) — so a visitor who APPROVED or RENAMED a seeded
  # record is reverted, not just left beside a fresh copy. A record a visitor
  # DELETED is recreated and its scoped grant re-pointed at the new row (the job
  # nukes all grants first, so plant! rebuilds them against the current records).
  #
  # plant! returns the ids that make up the seed set so the reset job can delete
  # everything a visitor added:
  #   { role_ids:, pay_runs:, contracts:, expense_claims: }
  module Seeds
    PASSWORD = "password"

    class << self
      def plant!
        @roles = []

        # The role-less account every anonymous hit is auto-signed-in as.
        User.visitor

        owner    = user("owner@example.com")
        reviewer = user("reviewer@example.com")
        member   = user("member@example.com")
        scoped   = user("scoped@example.com")

        CurrentScope.seed_defaults!
        owner_role  = track(CurrentScope::Role.find_by!(name: "Owner"))
        member_role = role("Member", %w[
          projects#index projects#show
          reports#index reports#show reports#new reports#create
        ])
        reviewer_role = role("Reviewer", member_role.permission_keys + %w[reports#approve])
        lister_role   = role("Lister", %w[projects#index reports#index])
        viewer_role   = role("Viewer", %w[reports#show])

        assign(owner => owner_role, reviewer => reviewer_role,
               member => member_role, scoped => lister_role)

        apollo = Project.find_or_create_by!(name: "Apollo")
        zephyr = Project.find_or_create_by!(name: "Zephyr")

        q3 = report("Q3 budget", project: apollo, requested_by: member)
        report("Q4 forecast", project: apollo, requested_by: reviewer)
        report("Zephyr kickoff", project: zephyr, requested_by: member)
        scoped_grant(scoped, viewer_role, q3)

        # The bystander holds no grants anywhere: default-denied everywhere.
        user("bystander@example.com")

        # Build the domain records FIRST (they register the 12 gallery roles via
        # @roles), THEN read role_ids — otherwise the map would miss them.
        pay_runs       = seed_payroll
        contracts      = seed_contracts
        expense_claims = seed_expenses

        { role_ids: @roles.map(&:id), pay_runs:, contracts:, expense_claims: }
      end

      private

      # Users keep a stable id (found, never recreated) and — crucially — no
      # bcrypt runs on the reset path: the password block only fires on CREATE,
      # so the reset transaction stays well under SQLite's ~5s busy timeout.
      def user(email)
        User.find_or_create_by!(email_address: email) { |u| u.password = PASSWORD }
      end

      def track(role) = @roles.push(role).last

      def role(name, permission_keys)
        r = track(CurrentScope::Role.find_or_create_by!(name: name))
        r.update!(permission_keys: permission_keys) # re-asserts the grid canonically
        r
      end

      def assign(pairs)
        pairs.each do |subject, role|
          CurrentScope::RoleAssignment.find_or_create_by!(subject: subject) { |a| a.role = role }
        end
      end

      def scoped_grant(subject, role, resource)
        CurrentScope::ScopedRoleAssignment.find_or_create_by!(subject: subject, role: role, resource: resource)
      end

      def report(title, project:, requested_by:)
        Report.find_or_create_by!(title: title) { |r| r.project = project; r.requested_by = requested_by }
      end

      # The three SoD gallery domains — same shape, one preparer / approver /
      # scoped-approver each, three records, a scoped grant on the first.

      def seed_payroll
        prep, appr, list, scoped_role = domain_roles("Payroll", "pay_runs")
        preparer    = assign_user("payroll.preparer@example.com", prep)
        approver    = assign_user("payroll.approver@example.com", appr)
        scoped_user = assign_user("payroll.scoped@example.com", list)

        a = pay_run("July salaries", period: "2026-07", amount: 84_200, prepared_by: preparer)
        b = pay_run("June salaries", period: "2026-06", amount: 81_050, prepared_by: approver)
        c = pay_run("May bonus run", period: "2026-05", amount: 12_500, prepared_by: preparer)
        scoped_grant(scoped_user, scoped_role, a)
        [ a.id, b.id, c.id ]
      end

      def seed_contracts
        prep, appr, list, scoped_role = domain_roles("Contracts", "contracts")
        raiser      = assign_user("contracts.raiser@example.com", prep)
        approver    = assign_user("contracts.approver@example.com", appr)
        scoped_user = assign_user("contracts.scoped@example.com", list)

        a = contract("Cloud hosting renewal", counterparty: "Northwind Infra", amount: 48_000, raised_by: raiser)
        b = contract("Office lease", counterparty: "Harbor Estates", amount: 120_000, raised_by: approver)
        c = contract("Support retainer", counterparty: "Beacon Partners", amount: 24_000, raised_by: raiser)
        scoped_grant(scoped_user, scoped_role, a)
        [ a.id, b.id, c.id ]
      end

      def seed_expenses
        prep, appr, list, scoped_role = domain_roles("Expenses", "expense_claims")
        submitter   = assign_user("expenses.submitter@example.com", prep)
        approver    = assign_user("expenses.approver@example.com", appr)
        scoped_user = assign_user("expenses.scoped@example.com", list)

        a = expense_claim("Conference travel", amount: 1_850, submitted_by: submitter)
        b = expense_claim("Team offsite catering", amount: 640, submitted_by: approver)
        c = expense_claim("New laptop", amount: 2_400, submitted_by: submitter)
        scoped_grant(scoped_user, scoped_role, a)
        [ a.id, b.id, c.id ]
      end

      def domain_roles(label, ctrl)
        base = %W[#{ctrl}#index #{ctrl}#show #{ctrl}#new #{ctrl}#create]
        [ role("#{label} Preparer", base),
          role("#{label} Approver", base + %W[#{ctrl}#approve]),
          role("#{label} Lister", %W[#{ctrl}#index]),
          role("#{label} Approver (scoped)", %W[#{ctrl}#show #{ctrl}#approve]) ]
      end

      def assign_user(email, role)
        subject = user(email)
        CurrentScope::RoleAssignment.find_or_create_by!(subject: subject) { |a| a.role = role }
        subject
      end

      # find_or_create_by! recreates a visitor-deleted record; update! reverts a
      # visitor-approved or re-costed one back to canonical, pending state.
      def pay_run(label, period:, amount:, prepared_by:)
        r = PayRun.find_or_create_by!(label: label) { |x| x.period = period; x.amount = amount; x.prepared_by = prepared_by }
        r.update!(period: period, amount: amount, prepared_by: prepared_by, **unapproved)
        r
      end

      def contract(title, counterparty:, amount:, raised_by:)
        r = Contract.find_or_create_by!(title: title) { |x| x.counterparty = counterparty; x.amount = amount; x.raised_by = raised_by }
        r.update!(counterparty: counterparty, amount: amount, raised_by: raised_by, **unapproved)
        r
      end

      def expense_claim(description, amount:, submitted_by:)
        r = ExpenseClaim.find_or_create_by!(description: description) { |x| x.amount = amount; x.submitted_by = submitted_by }
        r.update!(amount: amount, submitted_by: submitted_by, **unapproved)
        r
      end

      def unapproved = { approved_by: nil, approved_at: nil, status: "pending" }
    end
  end
end
