require "test_helper"

# One org-wide role per subject is a load-bearing uniqueness invariant
# (index_current_scope_one_role_per_subject). Dropping it would let find_by
# return an arbitrary row and flip grants unpredictably.
class RoleAssignmentTest < ActiveSupport::TestCase
  test "a second org-wide assignment for the same subject is refused" do
    alice = User.create!(name: "Alice")
    member = CurrentScope::Role.create!(name: "Member")
    editor = CurrentScope::Role.create!(name: "Editor")

    CurrentScope::RoleAssignment.create!(subject: alice, role: member)

    second = CurrentScope::RoleAssignment.new(subject: alice, role: editor)
    assert_not second.valid?
    assert second.errors[:base].any?
    message = second.errors.full_messages.join(" ")
    assert_match(/Subject already holds org-wide role "Member"/, message)
    assert_match(/CurrentScope\.grant!/, message)
    assert_match(/scoped roles/, message)
    assert_no_match(/has already been taken/, message)

    assert_equal 1, CurrentScope::RoleAssignment.where(subject: alice).count

    error = assert_raises(ActiveRecord::RecordInvalid) do
      CurrentScope::RoleAssignment.create!(subject: alice, role: editor)
    end
    assert_match(/Subject already holds org-wide role "Member"/, error.message)
    assert_match(/CurrentScope\.grant!/, error.message)
    assert_equal 1, CurrentScope::RoleAssignment.where(subject: alice).count
  end
end
