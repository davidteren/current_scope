require "test_helper"

# Server-side subject search (?q=): matches EVERY subject by its identity
# columns, so a query spans all pages — unlike the per-page client-side filter.
class SubjectsSearchTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(name: "Owner")
    CurrentScope::RoleAssignment.create!(
      subject: @owner, role: CurrentScope::Role.create!(name: "Owner", full_access: true))
  end

  def as(user) = { "X-User-Id" => user.id.to_s }

  test "?q= filters subjects server-side, excluding non-matches from the response" do
    User.create!(name: "Alice Cooper")
    User.create!(name: "Bob Dylan")

    get current_scope.subjects_url(q: "alice"), headers: as(@owner)
    assert_response :success
    assert_match "Alice Cooper", response.body
    # Server-side, not client-side: a non-match is absent from the HTML entirely
    # (a client filter would still render Bob's row, just hidden).
    assert_no_match(/Bob Dylan/, response.body)
  end

  test "search is case-insensitive" do
    User.create!(name: "Zeta")
    get current_scope.subjects_url(q: "ZETA"), headers: as(@owner)
    assert_match "Zeta", response.body
  end

  test "a blank query returns all subjects (no filtering)" do
    User.create!(name: "Gamma")
    get current_scope.subjects_url(q: ""), headers: as(@owner)
    assert_match "Gamma", response.body
    assert_match "Owner", response.body
  end

  test "the search box is a GET form that round-trips the query" do
    get current_scope.subjects_url(q: "owner"), headers: as(@owner)
    assert_select "form.cs-search[method=get] input[name=q][value=owner]"
  end

  test "finds a matching subject that would sit far past the first page" do
    60.times { |i| User.create!(name: "Filler #{format('%02d', i)}") } # > PER_PAGE(50)
    User.create!(name: "Zzyzx Findme") # highest id ⇒ a later page without search

    get current_scope.subjects_url(q: "findme"), headers: as(@owner)
    assert_response :success
    assert_select "td", text: "Zzyzx Findme"
    assert_select "tr[data-cs-row]", count: 1 # only the match
  end

  test "a query with SQL metacharacters is parameterized, not injected" do
    User.create!(name: "Normal Person")
    assert_nothing_raised do
      get current_scope.subjects_url(q: "'; DROP TABLE users; --"), headers: as(@owner)
    end
    assert_response :success
    assert User.exists?, "the users table survives — the query is a bound value, not SQL"
    assert_select "tr[data-cs-row]", count: 0
  end
end
