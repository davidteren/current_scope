# Demo data exercising every CurrentScope mechanism. Idempotent — the actual
# logic lives in Showcase::Seeds so the SandboxResetJob can replant the exact
# same ground truth on a schedule and on demand (see lib/showcase/seeds.rb).
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
# Plus the multi-domain SoD gallery (payroll / contracts / expenses): one
# preparer, approver, and scoped-approver per domain, and a single bystander
# with no grants anywhere.

Showcase::Seeds.plant!

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
