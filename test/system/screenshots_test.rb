require "application_system_test_case"

# Generates the README screenshots into docs/screenshots/. Skipped by default
# (so it never runs in CI); run it deliberately:
#
#   CAPTURE_SCREENSHOTS=1 RAILS_ENV=test bin/rails test test/system/screenshots_test.rb
#
# Reproducible: it seeds a small, representative data set and captures the five
# management-UI pages at a roomy width in the default (light) theme.
class ScreenshotsTest < ApplicationSystemTestCase
  DOCS = File.expand_path("../../docs/screenshots", __dir__)

  def readme_shot(name)
    FileUtils.mkdir_p(DOCS)
    page.save_screenshot(File.join(DOCS, "#{name}.png"))
  end

  test "capture README screenshots" do
    skip "set CAPTURE_SCREENSHOTS=1 to generate README images" unless ENV["CAPTURE_SCREENSHOTS"]

    owner = User.create!(name: "Olivia Owner")
    CurrentScope::RoleAssignment.create!(
      subject: owner, role: CurrentScope::Role.create!(name: "Owner", full_access: true))

    editor = CurrentScope::Role.create!(name: "Content Editor", description: "Edits and publishes content")
    %w[documents#index documents#show documents#new documents#create documents#edit documents#update
       reports#index reports#show].each { |k| editor.role_permissions.create!(permission_key: k) }
    approver = CurrentScope::Role.create!(name: "Report Approver", description: "May approve submitted reports")
    approver.role_permissions.create!(permission_key: "reports#approve")
    approver.role_permissions.create!(permission_key: "reports#index")
    viewer = CurrentScope::Role.create!(name: "Viewer", description: "Read-only across reports and documents")
    %w[reports#index reports#show documents#index documents#show].each { |k| viewer.role_permissions.create!(permission_key: k) }

    alice = User.create!(name: "Alice Adams")
    bob   = User.create!(name: "Bob Brown")
    carol = User.create!(name: "Carol Chen")
    dave  = User.create!(name: "Dave Diaz")
    CurrentScope::RoleAssignment.create!(subject: alice, role: editor)
    CurrentScope::RoleAssignment.create!(subject: bob, role: viewer)
    CurrentScope::RoleAssignment.create!(subject: carol, role: approver)

    q3 = Folder.create!(name: "Q3 Marketing Plan")
    deck = Folder.create!(name: "Board Deck")
    CurrentScope::ScopedRoleAssignment.create!(subject: dave, resource: q3, role: editor)
    CurrentScope::ScopedRoleAssignment.create!(subject: bob, resource: deck, role: viewer)

    # A few ledger rows for the events page.
    CurrentScope::Current.user = owner
    CurrentScope::Current.actor = owner
    CurrentScope::Event.record!(event: "role.created", target: editor, details: { name: "Content Editor" })
    CurrentScope::Event.record!(event: "org_role.assigned", target: alice, details: { role: "Content Editor" })
    CurrentScope::Event.record!(event: "scoped_role.granted", target: dave,
                                details: { role: "Content Editor", resource: "Q3 Marketing Plan" })
    CurrentScope::Current.reset

    sign_in(owner)
    current_window.resize_to(1360, 1000)

    visit "/current_scope/roles";                    readme_shot("roles")
    visit "/current_scope/roles/#{editor.id}/edit";  readme_shot("permission-grid")
    visit "/current_scope/subjects";                 readme_shot("subjects")
    visit "/current_scope/roles/#{editor.id}/members"; readme_shot("members")
    visit "/current_scope/events";                   readme_shot("events")

    %w[roles permission-grid subjects members events].each do |name|
      assert File.exist?(File.join(DOCS, "#{name}.png")), "missing screenshot #{name}.png"
    end
  end
end
