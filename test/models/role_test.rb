require "test_helper"

class RoleTest < ActiveSupport::TestCase
  test "permission_keys persist on save, filtered to the catalog" do
    role = CurrentScope::Role.new(name: "Editor")
    role.permission_keys = [ "", "reports#index", "bogus#nope" ]

    assert_equal [ "reports#index" ], role.permission_keys   # staged, readable pre-save
    assert_equal 0, CurrentScope::RolePermission.count       # nothing written yet

    role.save!
    assert_equal [ "reports#index" ], role.reload.permission_keys
  end

  test "a failed save leaves the existing permission set untouched" do
    role = CurrentScope::Role.create!(name: "Editor")
    role.permission_keys = %w[reports#index]
    role.save!

    assert_not role.update(name: "", permission_keys: %w[reports#destroy])
    assert_equal %w[reports#index], role.reload.permission_keys
  end
end
