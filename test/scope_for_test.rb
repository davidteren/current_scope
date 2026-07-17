require "test_helper"
require "current_scope/test_helpers"

# scope_for is the list-side complement to allowed_to?: same roles, same
# permission keys, same fail-closed rules — so the list and the per-record gate
# are one source of truth. SoD does NOT apply here (it vetoes record-targeted
# actions, not list membership), so these tests key off a non-SoD action.
class ScopeForTest < ActiveSupport::TestCase
  include CurrentScope::TestHelpers

  # A stand-in host that mixes in the portable helper — same reach as a view
  # or component (scope_for and allowed_to? both resolve the ambient subject).
  class Host
    include CurrentScope::Permissions
  end

  KEY = "projects#index" # what scope_for(Project) derives by default

  setup do
    @resolver = CurrentScope::Resolver.new
    @host = Host.new
    @alice = User.create!(name: "Alice")
    @p1 = Project.create!(name: "Apollo")
    @p2 = Project.create!(name: "Gemini")
    @p3 = Project.create!(name: "Mercury")
  end

  def role(name, *keys, full_access: false)
    r = CurrentScope::Role.create!(name: name, full_access: full_access)
    keys.each { |k| r.role_permissions.create!(permission_key: k) }
    r
  end

  def assign(user, role) = CurrentScope::RoleAssignment.create!(subject: user, role: role)

  def scope_grant(user, role, record)
    CurrentScope::ScopedRoleAssignment.create!(subject: user, role: role, resource: record)
  end

  test "a full_access org role sees every record of the type" do
    assign(@alice, role("Owner", full_access: true))
    assert_equal Project.ids.sort, @resolver.scope_for(subject: @alice, model: Project, permission: KEY).ids.sort
  end

  test "an org-wide grant of the key sees every record of the type" do
    assign(@alice, role("Member", KEY))
    assert_equal Project.ids.sort, @resolver.scope_for(subject: @alice, model: Project, permission: KEY).ids.sort
  end

  test "a scoped-only subject sees exactly the granted records, none of the siblings" do
    editor = role("Editor", KEY)
    scope_grant(@alice, editor, @p1)
    scope_grant(@alice, editor, @p3)

    assert_equal [ @p1.id, @p3.id ].sort,
      @resolver.scope_for(subject: @alice, model: Project, permission: KEY).ids.sort
  end

  # #65: for a listed read the record-less gate asks THIS query, so the two
  # halves cannot disagree — one claim, asked twice. Pinned from the list side.
  test "#65 agreement: the record-less gate opens iff this list is non-empty, full_access included" do
    scope_grant(@alice, role("Owner", full_access: true), @p1)

    assert_equal [ @p1.id ], @resolver.scope_for(subject: @alice, model: Project, permission: KEY).ids
    assert @resolver.allow?(subject: @alice, permission: KEY, record: nil, model: Project),
      "non-empty list ⇒ the gate agrees"

    @p1.destroy!
    assert_empty @resolver.scope_for(subject: @alice, model: Project, permission: KEY)
    assert_not @resolver.allow?(subject: @alice, permission: KEY, record: nil, model: Project),
      "empty list ⇒ the gate agrees with that too"
  end

  test "a scoped role that does NOT grant the key excludes that record" do
    viewer = role("Viewer", "projects#show") # scoped, but no projects#index
    scope_grant(@alice, viewer, @p1)

    assert_empty @resolver.scope_for(subject: @alice, model: Project, permission: KEY).to_a
  end

  test "no grants yields an empty relation" do
    assert_empty @resolver.scope_for(subject: @alice, model: Project, permission: KEY).to_a
  end

  test "a nil subject yields an empty relation (fail closed)" do
    assert_empty @resolver.scope_for(subject: nil, model: Project, permission: KEY).to_a
  end

  test "a model with zero rows yields an empty relation, no error" do
    Project.delete_all
    assign(@alice, role("Owner", full_access: true))
    assert_empty @resolver.scope_for(subject: @alice, model: Project, permission: KEY).to_a
  end

  test "returns a chainable ActiveRecord::Relation" do
    assign(@alice, role("Member", KEY))
    rel = @resolver.scope_for(subject: @alice, model: Project, permission: KEY)

    assert_kind_of ActiveRecord::Relation, rel
    assert_equal [ @p2.id ], rel.where(name: "Gemini").ids
  end

  test "the mixin derives the model's index key and resolves the ambient subject" do
    assign(@alice, role("Member", KEY))
    with_current_user(@alice) do
      assert_equal Project.ids.sort, @host.scope_for(Project).ids.sort
    end
  end

  # Load-bearing: the list and the per-record gate are one source of truth.
  # Over a seeded matrix, EVERY listed record passes allowed_to? and EVERY
  # excluded record fails it — asserted both directions.
  test "gate/list agreement: scope_for and allowed_to? never disagree" do
    full = User.create!(name: "Full")
    assign(full, role("Full", full_access: true))

    org = User.create!(name: "Org")
    assign(org, role("OrgIndex", KEY))

    scoped = User.create!(name: "Scoped")
    editor = role("Editor", KEY)
    scope_grant(scoped, editor, @p1)
    scope_grant(scoped, editor, @p3)

    none = User.create!(name: "None")

    [ full, org, scoped, none ].each do |subject|
      with_current_user(subject) do
        listed = @host.scope_for(Project).to_a
        Project.find_each do |record|
          if listed.include?(record)
            assert @host.allowed_to?(:index, record),
              "#{subject.name}: listed #{record.name} but the gate denied it"
          else
            assert_not @host.allowed_to?(:index, record),
              "#{subject.name}: excluded #{record.name} but the gate allowed it"
          end
        end
      end
    end
  end

  # The record-less companion to the matrix above: the gate decides whether the
  # subject reaches the list at all, scope_for decides what is in it. Within a
  # resource type they agree — anyone scope_for gives rows to can open the list,
  # and anyone it gives nothing to cannot.
  #
  # Not a biconditional ACROSS types: the record-less gate matches on subject +
  # role, while scope_for also filters resource_type. A subject scoped on a
  # Report under a bundled role that also ticks projects#index therefore passes
  # the projects#index gate and gets an empty list. Fail-closed on the data, so
  # a confusing surface rather than a hole — the resolver has no model to filter
  # on for the nil target ("projects#index" is a controller key, not a model
  # name), so closing it needs the Guard to pass the controller's model. Tracked
  # with OQ-2 rather than papered over here.
  test "gate/list agreement: a record-less check and scope_for agree within a type" do
    scoped = User.create!(name: "Scoped")
    scope_grant(scoped, role("Editor", KEY), @p1)

    show_only = User.create!(name: "ShowOnly")
    scope_grant(show_only, role("Viewer", "projects#show"), @p1)

    none = User.create!(name: "None")

    with_current_user(scoped) do
      assert @host.allowed_to?(:index, Project), "scope_for hands them rows, so the list must open"
      assert_equal [ @p1.id ], @host.scope_for(Project).ids
    end

    [ show_only, none ].each do |subject|
      with_current_user(subject) do
        assert_not @host.allowed_to?(:index, Project),
          "#{subject.name}: scope_for hands them nothing, so the list must stay shut"
        assert_empty @host.scope_for(Project).to_a
      end
    end
  end

  test "under act-as, scope_for follows the effective subject (user), not the actor" do
    assign(@alice, role("Member", KEY)) # effective subject may list all
    actor = User.create!(name: "Actor") # actor holds no grants

    with_current_user(@alice, actor: actor) do
      assert_equal Project.ids.sort, @host.scope_for(Project).ids.sort
    end

    # Converse: a granted actor behind an ungranted subject lists nothing —
    # the relation follows user, never actor.
    ungranted = User.create!(name: "Ungranted")
    granted_actor = User.create!(name: "GrantedActor")
    assign(granted_actor, role("ActorRole", KEY))

    with_current_user(ungranted, actor: granted_actor) do
      assert_empty @host.scope_for(Project).to_a
    end
  end
end
