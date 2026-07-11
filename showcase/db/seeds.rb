# Demo data exercising every CurrentScope mechanism. Idempotent.
#
# Sign in as (password is "password" for everyone):
#   owner@example.com    — Owner (full_access): sees everything, manages roles
#   reviewer@example.com — Reviewer: can view and approve reports (but never
#                          their own — SoD veto)
#   member@example.com   — Member: can view projects/reports and create
#                          reports; no approve, no destroy
#   scoped@example.com   — can only list; holds a scoped Viewer role granting
#                          reports#show on ONE report only
#
# Plus the multi-domain SoD gallery (payroll / contracts / expenses) seeded
# further down — one preparer, approver, and scoped-approver per domain, and a
# single bystander with no grants anywhere.

password = "password"

# The Visitor: the role-less account every anonymous hit is auto-signed-in as.
# It holds NO role (fail-closed, it can do almost nothing) and initiates NO
# record — so acting-as never trips the :either SoD veto on the real actor.
User.visitor

owner    = User.find_or_create_by!(email_address: "owner@example.com")    { |u| u.password = password }
reviewer = User.find_or_create_by!(email_address: "reviewer@example.com") { |u| u.password = password }
member   = User.find_or_create_by!(email_address: "member@example.com")   { |u| u.password = password }
scoped   = User.find_or_create_by!(email_address: "scoped@example.com")   { |u| u.password = password }

CurrentScope.seed_defaults!
owner_role  = CurrentScope::Role.find_by!(name: "Owner")
member_role = CurrentScope::Role.find_by!(name: "Member")

member_role.update!(permission_keys: %w[
  projects#index projects#show
  reports#index reports#show reports#new reports#create
])

reviewer_role = CurrentScope::Role.find_or_create_by!(name: "Reviewer")
reviewer_role.update!(permission_keys: member_role.permission_keys + %w[reports#approve])

lister_role = CurrentScope::Role.find_or_create_by!(name: "Lister")
lister_role.update!(permission_keys: %w[projects#index reports#index])

viewer_role = CurrentScope::Role.find_or_create_by!(name: "Viewer")
viewer_role.update!(permission_keys: %w[reports#show])

{
  owner => owner_role, reviewer => reviewer_role,
  member => member_role, scoped => lister_role
}.each do |user, role|
  CurrentScope::RoleAssignment.find_or_create_by!(subject: user) { |a| a.role = role }
end

apollo = Project.find_or_create_by!(name: "Apollo")
zephyr = Project.find_or_create_by!(name: "Zephyr")

q3 = Report.find_or_create_by!(title: "Q3 budget", project: apollo, requested_by: member)
Report.find_or_create_by!(title: "Q4 forecast", project: apollo, requested_by: reviewer)
Report.find_or_create_by!(title: "Zephyr kickoff", project: zephyr, requested_by: member)

# scoped@ can open ONLY the Q3 budget report, via a scoped role on that record.
CurrentScope::ScopedRoleAssignment.find_or_create_by!(subject: scoped, role: viewer_role, resource: q3)

# --- Multi-domain SoD gallery -------------------------------------------------
# Every domain has the same four resolver branches:
#   preparer  — org role: create + read, NO approve
#   approver  — org role: approve anyone's record (but never their own — SoD)
#   scoped    — org "lister" role (enough to reach the index) + a scoped role
#               granting show + approve on exactly ONE record
#   bystander — no grants anywhere: default-denied everywhere
bystander = User.find_or_create_by!(email_address: "bystander@example.com") { |u| u.password = password }

# Builds the four roles for a domain and returns them.
seed_roles = lambda do |label, ctrl|
  base = %W[#{ctrl}#index #{ctrl}#show #{ctrl}#new #{ctrl}#create]
  preparer = CurrentScope::Role.find_or_create_by!(name: "#{label} Preparer")
  preparer.update!(permission_keys: base)
  approver = CurrentScope::Role.find_or_create_by!(name: "#{label} Approver")
  approver.update!(permission_keys: base + %W[#{ctrl}#approve])
  lister = CurrentScope::Role.find_or_create_by!(name: "#{label} Lister")
  lister.update!(permission_keys: %W[#{ctrl}#index])
  scoped_role = CurrentScope::Role.find_or_create_by!(name: "#{label} Approver (scoped)")
  scoped_role.update!(permission_keys: %W[#{ctrl}#show #{ctrl}#approve])
  [ preparer, approver, lister, scoped_role ]
end

# Finds/creates a user and pins them to one org role (idempotent).
assign_user = lambda do |email, role|
  user = User.find_or_create_by!(email_address: email) { |u| u.password = password }
  CurrentScope::RoleAssignment.find_or_create_by!(subject: user) { |a| a.role = role }
  user
end

# Payroll -----------------------------------------------------------------------
pr_prep, pr_appr, pr_list, pr_scoped = seed_roles.call("Payroll", "pay_runs")
pr_preparer = assign_user.call("payroll.preparer@example.com", pr_prep)
assign_user.call("payroll.approver@example.com", pr_appr)
pr_scoped_user = assign_user.call("payroll.scoped@example.com", pr_list)
pr_appr_user = User.find_by!(email_address: "payroll.approver@example.com")

pr_a = PayRun.find_or_create_by!(label: "July salaries")   { |r| r.period = "2026-07"; r.amount = 84_200; r.prepared_by = pr_preparer }
PayRun.find_or_create_by!(label: "June salaries")          { |r| r.period = "2026-06"; r.amount = 81_050; r.prepared_by = pr_appr_user }
PayRun.find_or_create_by!(label: "May bonus run")          { |r| r.period = "2026-05"; r.amount = 12_500; r.prepared_by = pr_preparer }
CurrentScope::ScopedRoleAssignment.find_or_create_by!(subject: pr_scoped_user, role: pr_scoped, resource: pr_a)

# Contracts ---------------------------------------------------------------------
ct_prep, ct_appr, ct_list, ct_scoped = seed_roles.call("Contracts", "contracts")
ct_preparer = assign_user.call("contracts.raiser@example.com", ct_prep)
assign_user.call("contracts.approver@example.com", ct_appr)
ct_scoped_user = assign_user.call("contracts.scoped@example.com", ct_list)
ct_appr_user = User.find_by!(email_address: "contracts.approver@example.com")

ct_a = Contract.find_or_create_by!(title: "Cloud hosting renewal") { |r| r.counterparty = "Northwind Infra"; r.amount = 48_000; r.raised_by = ct_preparer }
Contract.find_or_create_by!(title: "Office lease")                 { |r| r.counterparty = "Harbor Estates"; r.amount = 120_000; r.raised_by = ct_appr_user }
Contract.find_or_create_by!(title: "Support retainer")            { |r| r.counterparty = "Beacon Partners"; r.amount = 24_000; r.raised_by = ct_preparer }
CurrentScope::ScopedRoleAssignment.find_or_create_by!(subject: ct_scoped_user, role: ct_scoped, resource: ct_a)

# Expenses ----------------------------------------------------------------------
ex_prep, ex_appr, ex_list, ex_scoped = seed_roles.call("Expenses", "expense_claims")
ex_preparer = assign_user.call("expenses.submitter@example.com", ex_prep)
assign_user.call("expenses.approver@example.com", ex_appr)
ex_scoped_user = assign_user.call("expenses.scoped@example.com", ex_list)
ex_appr_user = User.find_by!(email_address: "expenses.approver@example.com")

ex_a = ExpenseClaim.find_or_create_by!(description: "Conference travel")   { |r| r.amount = 1_850; r.submitted_by = ex_preparer }
ExpenseClaim.find_or_create_by!(description: "Team offsite catering")      { |r| r.amount = 640; r.submitted_by = ex_appr_user }
ExpenseClaim.find_or_create_by!(description: "New laptop")                 { |r| r.amount = 2_400; r.submitted_by = ex_preparer }
CurrentScope::ScopedRoleAssignment.find_or_create_by!(subject: ex_scoped_user, role: ex_scoped, resource: ex_a)

puts <<~CREDS
  Seeded. Password is "password" for everyone.

  Just open the app: you land as the role-less Visitor and step into any persona
  below in one click (the act-as switcher). No sign-in needed to explore.

  Reports (the reference domain):
    owner@example.com     — full access, everywhere
    reviewer@example.com  — approve reports (never own)
    member@example.com    — create/read reports, no approve
    scoped@example.com    — scoped: opens exactly one report

  Gallery — one preparer / approver / scoped-approver per domain:
    payroll.preparer@example.com   payroll.approver@example.com   payroll.scoped@example.com
    contracts.raiser@example.com   contracts.approver@example.com contracts.scoped@example.com
    expenses.submitter@example.com expenses.approver@example.com  expenses.scoped@example.com

    bystander@example.com          — no grants anywhere: default-denied
CREDS
