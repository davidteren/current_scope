require "test_helper"

# permission_keys= is a security-grant API, so an unknown key must be LOUD.
# It used to be silently scrubbed at assignment: a typo, or a programmatic grant
# of an unrouted key, vanished with no error and a clean save — leaving a role
# that looks right and denies at runtime for no visible reason. Rejection is now
# a validation failure; the deliberate stale-key scrub moved behind an explicit
# opt-in (assign_permission_keys(..., scrub: true)).
class RoleTest < ActiveSupport::TestCase
  # --- R1: unknown keys make the record invalid ---

  test "a typo'd key makes the role invalid and names the key" do
    role = CurrentScope::Role.new(name: "Editor")
    role.permission_keys = %w[reports#aprove reports#approve]

    assert_not role.save, "a key that is not in the catalog must not save silently"
    assert_includes role.errors[:permission_keys].first, "reports#aprove"
    assert_equal 0, CurrentScope::RolePermission.count, "a failed save persists nothing"
  end

  test "save! raises on an unknown key" do
    role = CurrentScope::Role.create!(name: "Editor")

    assert_raises(ActiveRecord::RecordInvalid) do
      role.update!(permission_keys: %w[legacy#does_not_exist])
    end
  end

  test "the error message points at the scrub opt-in" do
    role = CurrentScope::Role.new(name: "Editor")
    role.permission_keys = %w[gone#index]
    role.validate

    assert_includes role.errors[:permission_keys].first, "scrub: true"
  end

  # The break-glass permission can never be in a route-derived catalog: it is a
  # bare action name ("bypass_sod"), not a controller#action key, so no route
  # can produce it — which is exactly why it was ALWAYS dropped. A seed granting
  # it saved cleanly and produced a role that could never bypass. Still not
  # grantable (that is #21) — but now it says so instead of lying.
  test "granting the never-routed bypass permission errors instead of vanishing" do
    key = CurrentScope.config.sod_bypass_permission.to_s
    # Assert the SHAPE, not just absence: `catalog.include?(key)` being false
    # proves nothing on its own — every catalog key is "controller#action", so a
    # bare name misses by construction rather than by not being routed.
    assert_not_includes key, "#", "precondition: the bypass permission is a bare action name"
    assert_not CurrentScope.catalog.include?(key)

    role = CurrentScope::Role.new(name: "Breakglass")
    role.permission_keys = [ key ]

    assert_not role.save
    assert_includes role.errors[:permission_keys].first, key
  end

  # --- R2: blanks are form padding, not typos ---

  test "blank entries are dropped silently, not treated as unknown keys" do
    role = CurrentScope::Role.new(name: "Editor")
    role.permission_keys = [ "", "reports#index", "" ]

    assert role.save, "the hidden-field padding the grid submits must not be an error"
    assert_equal %w[reports#index], role.reload.permission_keys
  end

  # --- The happy path is unchanged ---

  test "an all-catalog set stages, then persists on save" do
    role = CurrentScope::Role.new(name: "Editor")
    role.permission_keys = %w[reports#index reports#approve]

    assert_equal %w[reports#index reports#approve], role.permission_keys # staged, readable pre-save
    assert_equal 0, CurrentScope::RolePermission.count                   # nothing written yet

    role.save!
    assert_equal %w[reports#index reports#approve].sort, role.reload.permission_keys.sort
  end

  test "the staged reader shows what was assigned, including a key about to be rejected" do
    role = CurrentScope::Role.new(name: "Editor")
    role.permission_keys = %w[reports#index bogus#nope]

    # Honest rather than flattering: the old reader hid the bad key at
    # assignment, so the operator never saw what they were about to lose.
    assert_equal %w[reports#index bogus#nope], role.permission_keys
  end

  test "a failed save leaves the existing permission set untouched" do
    role = CurrentScope::Role.create!(name: "Editor")
    role.permission_keys = %w[reports#index]
    role.save!

    assert_not role.update(name: "", permission_keys: %w[reports#destroy])
    assert_equal %w[reports#index], role.reload.permission_keys
  end

  test "keys are deduped" do
    role = CurrentScope::Role.new(name: "Editor")
    role.permission_keys = %w[reports#index reports#index]

    assert role.save
    assert_equal %w[reports#index], role.reload.permission_keys
  end

  # --- R4: the scrub opt-in ---

  test "scrub: true drops non-catalog keys silently, as the cleanup case needs" do
    role = CurrentScope::Role.new(name: "Editor")
    role.assign_permission_keys(%w[reports#index gone#index], scrub: true)

    assert role.save, "the deliberate stale-key cleanup must stay possible"
    assert_equal %w[reports#index], role.reload.permission_keys
  end

  test "scrub cannot leak through mass assignment" do
    role = CurrentScope::Role.create!(name: "Editor")

    # The escape hatch is a named method precisely so form params can never
    # reach it — otherwise the silent-drop hole reopens on the UI path.
    assert_not role.update(permission_keys: %w[gone#index])
  end

  # Ruby truthiness would let "false" — or any params/config value passed
  # along — silently disable the strict path, which is the hole this whole API
  # exists to close.
  test "only literal true opens the scrub hatch" do
    [ "false", "true", "0", 1, Object.new, :true ].each do |truthy|
      role = CurrentScope::Role.new(name: "Editor #{truthy.class}#{truthy.object_id}")
      role.assign_permission_keys(%w[gone#index], scrub: truthy)

      assert_not role.save, "scrub: #{truthy.inspect} must not disable validation"
    end
  end

  test "falsey scrub values stay strict" do
    [ false, nil ].each do |falsey|
      role = CurrentScope::Role.new(name: "Editor #{falsey.inspect}")
      role.assign_permission_keys(%w[gone#index], scrub: falsey)

      assert_not role.save
    end
  end

  # --- R5: what was rejected is observable ---

  test "the change diff reports rejected keys, and added/removed only what persisted" do
    role = CurrentScope::Role.create!(name: "Editor")
    role.assign_permission_keys(%w[reports#index gone#index legacy#stats], scrub: true)
    role.save!

    assert_equal %w[gone#index legacy#stats].sort, role.permission_keys_change[:rejected].sort
    assert_equal %w[reports#index], role.permission_keys_change[:added]
    assert_empty role.permission_keys_change[:removed]
  end

  test "the rejected diff is empty on an all-catalog save" do
    role = CurrentScope::Role.create!(name: "Editor")
    role.permission_keys = %w[reports#index]
    role.save!

    assert_empty role.permission_keys_change[:rejected]
  end

  # --- R3: nothing unknown ever reaches the table ---

  test "no unknown key is ever persisted, by either path" do
    strict = CurrentScope::Role.new(name: "Strict")
    strict.permission_keys = %w[reports#index bogus#nope]
    strict.save # invalid — persists nothing

    scrubbed = CurrentScope::Role.create!(name: "Scrubbed")
    scrubbed.assign_permission_keys(%w[reports#index bogus#nope], scrub: true)
    scrubbed.save!

    CurrentScope::RolePermission.pluck(:permission_key).each do |key|
      assert CurrentScope.catalog.include?(key), "#{key} reached the table but is not in the catalog"
    end
  end

  test "reload clears staged keys and scrub intent" do
    role = CurrentScope::Role.create!(name: "Editor")
    role.permission_keys = %w[reports#index]
    role.save!

    role.assign_permission_keys(%w[gone#index], scrub: true)
    role.reload

    assert_equal %w[reports#index], role.permission_keys, "reload must read from the table"

    # The scrub intent must not survive to license a later strict assignment.
    role.permission_keys = %w[gone#index]
    assert_not role.valid?
  end

  test "a save clears scrub intent, so the next strict assignment is still strict" do
    role = CurrentScope::Role.create!(name: "Editor")
    role.assign_permission_keys(%w[gone#index], scrub: true)
    role.save!

    role.permission_keys = %w[still#bogus]
    assert_not role.valid?, "scrub intent must not persist across saves"
  end
end
