require "test_helper"

# A12 (part 1): the subjects page and events index paginate rather than dumping
# the whole table (events previously had a hard 200 cap).
class PaginationTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(name: "Owner")
    owner_role = CurrentScope::Role.create!(name: "Owner", full_access: true)
    CurrentScope::RoleAssignment.create!(subject: @owner, role: owner_role)
  end

  def as(user) = { "X-User-Id" => user.id.to_s }

  test "subjects page caps at PER_PAGE and reaches the overflow on page 2" do
    per = CurrentScope::SubjectsController::PER_PAGE
    last = nil
    (per + 2).times { |i| last = User.create!(name: "PagUser#{i}") } # + @owner spills past one page

    get current_scope.subjects_url, headers: as(@owner) # page 1
    assert_response :success
    assert_match(/page=2/, response.body, "page 1 should link to a next page")
    assert_not_includes response.body, last.name, "the overflow subject must not be on page 1"

    get current_scope.subjects_url(page: 2), headers: as(@owner)
    assert_response :success
    assert_includes response.body, last.name, "the overflow subject must appear on page 2"
  end

  test "events index paginates instead of a hard cap" do
    per = CurrentScope::EventsController::PER_PAGE
    gid = @owner.to_gid.to_s
    # id DESC order → the FIRST-created row is oldest and lands on page 2.
    oldest_label = "LedgerRow0"
    (per + 2).times do |i|
      CurrentScope::Event.create!(event: "role.created", actor: gid, subject: gid,
                                  target: gid, target_label: "LedgerRow#{i}")
    end

    get current_scope.events_url, headers: as(@owner) # page 1 (newest PER_PAGE)
    assert_response :success
    assert_match(/page=2/, response.body)
    assert_not_includes response.body, oldest_label

    get current_scope.events_url(page: 2), headers: as(@owner)
    assert_response :success
    assert_includes response.body, oldest_label
  end
end
