require "test_helper"

# The subjects page is the admin's main tool for granting and reviewing roles,
# and config.subject_label is host code that runs once per row. One subject the
# Proc can't handle must not take the page down — proven here through a real
# request, because the unit tests exercise the helper, not the render. (#22)
#
# The dummy's User has only `name`, so the Proc trips on a specific subject
# rather than on a nil attribute; the shape under test is the same (a host Proc
# that is fine for most rows and raises on one), and the exact nil-attribute
# repro from the issue is covered in test/helpers/application_helper_test.rb.
class SubjectLabelIsolationTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(name: "Owner")
    CurrentScope::RoleAssignment.create!(
      subject: @owner, role: CurrentScope::Role.create!(name: "Owner", full_access: true))
    @original_label = CurrentScope.config.subject_label
  end

  teardown do
    CurrentScope.config.subject_label = @original_label
    CurrentScope::ApplicationHelper.instance_variable_set(:@subject_label_warnings, nil)
  end

  def as(user) = { "X-User-Id" => user.id.to_s }

  test "a subject_label Proc that raises on one subject still renders the page" do
    CurrentScope.config.subject_label = lambda { |u|
      raise NoMethodError, "undefined method 'upcase' for nil" if u.name == "Ada Lovelace"

      u.name.upcase
    }
    User.create!(name: "Ada Lovelace")

    get current_scope.subjects_url, headers: as(@owner)

    assert_response :success, "one subject the Proc can't label must not 500 the subjects page"
    assert_match "Ada Lovelace", response.body, "the bad row falls back to its default label"
  end

  test "the good rows still get their configured label on the same page" do
    CurrentScope.config.subject_label = lambda { |u|
      raise NoMethodError, "boom" if u.name == "Ada Lovelace"

      u.name.upcase
    }
    User.create!(name: "Ada Lovelace")  # bad row
    User.create!(name: "Grace Hopper")  # good row

    get current_scope.subjects_url, headers: as(@owner)

    assert_response :success
    assert_match "GRACE HOPPER", response.body, "a bad row must not degrade the rows around it"
    assert_match "Ada Lovelace", response.body
  end
end
