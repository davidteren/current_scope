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

password = "password"
owner    = User.find_or_create_by!(email_address: "owner@example.com")    { |u| u.password = password }
reviewer = User.find_or_create_by!(email_address: "reviewer@example.com") { |u| u.password = password }
member   = User.find_or_create_by!(email_address: "member@example.com")   { |u| u.password = password }
scoped   = User.find_or_create_by!(email_address: "scoped@example.com")   { |u| u.password = password }

CurrentScope.seed_defaults!
owner_role  = CurrentScope::Role.find_by!(name: "Owner")
member_role = CurrentScope::Role.find_by!(name: "Member")

member_role.permission_keys = %w[
  projects#index projects#show
  reports#index reports#show reports#new reports#create
]

reviewer_role = CurrentScope::Role.find_or_create_by!(name: "Reviewer")
reviewer_role.permission_keys = member_role.permission_keys + %w[reports#approve]

lister_role = CurrentScope::Role.find_or_create_by!(name: "Lister")
lister_role.permission_keys = %w[projects#index reports#index]

viewer_role = CurrentScope::Role.find_or_create_by!(name: "Viewer")
viewer_role.permission_keys = %w[reports#show]

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

puts "Seeded. Sign in with owner@example.com / password (and friends)."
