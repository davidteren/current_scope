require "test_helper"

# A14: the scoped-role picker filters records for a type. Without a hook it scans
# rows and filters the Ruby-computed label; with an opt-in
# current_scope_searchable_scope class method it searches via indexed SQL.
class PickerSearchTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(name: "Owner")
    owner_role = CurrentScope::Role.create!(name: "Owner", full_access: true)
    CurrentScope::RoleAssignment.create!(subject: @owner, role: owner_role)
    @alpha = Folder.create!(name: "Alpha")
    @beta = Folder.create!(name: "Beta")
  end

  def as(user) = { "X-User-Id" => user.id.to_s }

  test "fallback (no hook): a non-matching query filters everything out via the Ruby label scan" do
    assert_not_respond_to Folder, :current_scope_searchable_scope
    get current_scope.new_scoped_role_assignment_url(resource_type: "Folder", q: "zzz"), headers: as(@owner)
    assert_response :success
    assert_not_includes response.body, "Alpha"
    assert_not_includes response.body, "Beta"
  end

  test "with the opt-in search hook, the model's scope drives the results (not the Ruby label filter)" do
    # A hook that ignores the term and returns all rows — so a term the label
    # filter would reject still yields results, proving the hook path was taken.
    Folder.define_singleton_method(:current_scope_searchable_scope) { |_term| all }

    get current_scope.new_scoped_role_assignment_url(resource_type: "Folder", q: "zzz"), headers: as(@owner)
    assert_response :success
    assert_includes response.body, "Alpha"
    assert_includes response.body, "Beta"
  ensure
    Folder.singleton_class.send(:remove_method, :current_scope_searchable_scope)
  end
end
