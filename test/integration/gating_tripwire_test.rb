require "test_helper"

# A4: the opt-in tripwire catches an action that completed without being gated,
# on a controller that never included Guard — the case Guard's own after_action
# cannot see. It carries its OWN skip API (skip_before_action :current_scope_check!
# would raise at class load on such a controller).
class GatingTripwireTest < ActionDispatch::IntegrationTest
  def sign_in(user) = { "X-User-Id" => user.id.to_s }

  test "an ungated action (tripwire mixin, no Guard) trips the tripwire" do
    error = assert_raises(CurrentScope::ConfigurationError) do
      get tripwire_open_url
    end
    assert_match "current_scope_check!", error.message
  end

  test "an action marked with the mixin's own skip API does not trip" do
    get tripwire_public_url
    assert_response :success
  end

  test "a Guard'd action that ran the gate does not trip" do
    owner = User.create!(name: "Owner")
    role = CurrentScope::Role.create!(name: "Owner", full_access: true)
    CurrentScope::RoleAssignment.create!(subject: owner, role: role)

    get tripwire_gated_url, headers: sign_in(owner)
    assert_response :success
  end
end
