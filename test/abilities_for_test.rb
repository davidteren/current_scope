require "test_helper"

# abilities_for is an advisory snapshot for a client. It packages the resolver's
# full_access flag, the org role, that role's permission keys, and bounded id
# lists from scope_for. It does not change allow?, and it does not apply the
# separation-of-duties veto.
class AbilitiesForTest < ActiveSupport::TestCase
  PROJECT_KEY = "projects#index"
  REPORT_KEY = "reports#show"
  LEDGER_KEY = "ledgers#index"

  setup do
    @alice = User.create!(name: "Alice")
    @p1 = Project.create!(name: "Apollo")
    @p2 = Project.create!(name: "Gemini")
    @p3 = Project.create!(name: "Mercury")
  end

  def role(name, *keys, full_access: false)
    record = CurrentScope::Role.create!(name: name, full_access: full_access)
    keys.each { |key| record.role_permissions.create!(permission_key: key) }
    record
  end

  def assign(user, assigned_role)
    CurrentScope::RoleAssignment.create!(subject: user, role: assigned_role)
  end

  def scope_grant(user, assigned_role, record)
    CurrentScope::ScopedRoleAssignment.create!(subject: user, role: assigned_role, resource: record)
  end

  def listed_ids(subject, model, permission)
    CurrentScope.scope_for(subject: subject, model: model, permission: permission)
      .reorder(model.primary_key)
      .pluck(model.primary_key)
  end

  def scope_calls
    calls = []
    resolver = CurrentScope.resolver
    original = resolver.method(:scope_for)
    resolver.define_singleton_method(:scope_for) do |subject:, model:, permission:|
      calls << [ subject, model, permission ]
      original.call(subject: subject, model: model, permission: permission)
    end
    yield
    calls
  ensure
    if resolver&.singleton_class&.method_defined?(:scope_for, false)
      resolver.singleton_class.remove_method(:scope_for)
    end
  end

  test "a full-access subject under the limit returns those ids and is not truncated" do
    owner = role("Owner", full_access: true)
    assign(@alice, owner)

    payload = CurrentScope.abilities_for(
      @alice,
      scopes: [ [ Project, PROJECT_KEY ] ],
      limit: 10
    )

    assert_equal CurrentScope::VERSION, payload[:version]
    assert_equal true, payload[:full_access]
    assert_equal "Owner", payload[:org_role]
    assert_equal owner.permission_keys, payload[:permission_keys]
    assert_equal [], payload[:permission_keys]
    entry = payload[:scoped].sole
    assert_equal "Project", entry[:model]
    assert_equal PROJECT_KEY, entry[:permission]
    assert_equal listed_ids(@alice, Project, PROJECT_KEY), entry[:ids]
    assert_equal [ @p1.id, @p2.id, @p3.id ], entry[:ids]
    assert_equal false, entry[:truncated]
  end

  test "more ids than the limit returns the primary-key cut and marks it truncated" do
    editor = role("Editor", PROJECT_KEY)
    scope_grant(@alice, editor, @p1)
    scope_grant(@alice, editor, @p2)
    scope_grant(@alice, editor, @p3)

    payload = CurrentScope.abilities_for(
      @alice,
      scopes: [ [ Project, PROJECT_KEY ] ],
      limit: 2
    )
    entry = payload[:scoped].sole
    expected = listed_ids(@alice, Project, PROJECT_KEY)

    assert_equal expected.first(2), entry[:ids]
    assert_equal 2, entry[:ids].length
    assert_equal true, entry[:truncated]
    assert_includes expected, expected.last
    refute_includes entry[:ids], expected.last
  end

  test "a subject with only a scoped grant has no org role and still lists the granted ids" do
    editor = role("Editor", PROJECT_KEY)
    scope_grant(@alice, editor, @p1)
    scope_grant(@alice, editor, @p3)

    payload = CurrentScope.abilities_for(
      @alice,
      scopes: [ [ Project, PROJECT_KEY ] ],
      limit: 2
    )
    entry = payload[:scoped].sole

    assert_equal false, payload[:full_access]
    assert_nil payload[:org_role]
    assert_equal [], payload[:permission_keys]
    assert_equal [ @p1.id, @p3.id ].sort, entry[:ids].sort
    assert_equal false, entry[:truncated]
  end

  test "an empty permission key list is not full access" do
    assign(@alice, role("Member"))

    payload = CurrentScope.abilities_for(
      @alice,
      scopes: [ [ Project, PROJECT_KEY ] ],
      limit: 10
    )
    entry = payload[:scoped].sole

    assert_equal false, payload[:full_access]
    assert_equal "Member", payload[:org_role]
    assert_equal [], payload[:permission_keys]
    assert_equal [], entry[:ids]
    assert_equal false, entry[:truncated]
  end

  test "permission keys do not stand in for another model's scoped ids" do
    assign(@alice, role("Member", PROJECT_KEY))
    report = Report.create!(title: "One", requested_by: @alice, project: @p1)

    payload = CurrentScope.abilities_for(
      @alice,
      scopes: [ [ Project, PROJECT_KEY ], [ Report, REPORT_KEY ] ],
      limit: 10
    )

    assert_equal [ PROJECT_KEY ], payload[:permission_keys]
    assert_equal false, payload[:full_access]
    assert_equal listed_ids(@alice, Project, PROJECT_KEY), payload[:scoped][0][:ids]
    assert_equal [], payload[:scoped][1][:ids]
    refute_includes payload[:scoped][1][:ids], report.id
  end

  test "a nil subject fails closed and does not list ids" do
    assign(@alice, role("Owner", full_access: true))

    payload = nil
    assert_nothing_raised do
      payload = CurrentScope.abilities_for(
        nil,
        scopes: [ [ Project, PROJECT_KEY ] ],
        limit: 10
      )
    end

    assert_equal false, payload[:full_access]
    assert_nil payload[:org_role]
    assert_equal [], payload[:permission_keys]
    assert_equal [], payload[:scoped].sole[:ids]
    assert_equal false, payload[:scoped].sole[:truncated]
  end

  test "a bad limit raises before scope_for runs" do
    [ nil, 0, -1, "2", "0", 1.5, true ].each do |limit|
      calls = scope_calls do
        assert_no_queries do
          assert_raises(ArgumentError) do
            CurrentScope.abilities_for(@alice, scopes: [ [ Project, PROJECT_KEY ] ], limit: limit)
          end
        end
      end

      assert_empty calls, "limit #{limit.inspect} must not call scope_for"
    end
  end

  test "omitting limit raises and does not call scope_for" do
    calls = scope_calls do
      assert_no_queries do
        assert_raises(ArgumentError) do
          CurrentScope.abilities_for(@alice, scopes: [ [ Project, PROJECT_KEY ] ])
        end
      end
    end

    assert_empty calls
  end

  test "two pairs are not expanded into a cross product" do
    scope_grant(@alice, role("Indexer", PROJECT_KEY), @p1)
    report = Report.create!(title: "One", requested_by: @alice, project: @p2)
    scope_grant(@alice, role("Reader", REPORT_KEY), report)

    payload = nil
    calls = scope_calls do
      payload = CurrentScope.abilities_for(
        @alice,
        scopes: [ [ Project, PROJECT_KEY ], [ Report, REPORT_KEY ] ],
        limit: 10
      )
    end

    assert_equal [ [ @alice, Project, PROJECT_KEY ], [ @alice, Report, REPORT_KEY ] ], calls
    assert_equal [ "Project", "Report" ], payload[:scoped].map { |entry| entry[:model] }
    assert_equal [ PROJECT_KEY, REPORT_KEY ], payload[:scoped].map { |entry| entry[:permission] }
    assert_equal [ @p1.id ], payload[:scoped][0][:ids]
    assert_equal [ report.id ], payload[:scoped][1][:ids]
  end

  test "duplicate pairs each call scope_for once" do
    calls = scope_calls do
      CurrentScope.abilities_for(
        @alice,
        scopes: [ [ Project, PROJECT_KEY ], [ Project, PROJECT_KEY ] ],
        limit: 1
      )
    end

    assert_equal 2, calls.length
    assert_equal [ Project, PROJECT_KEY ], calls[0][1..]
    assert_equal [ Project, PROJECT_KEY ], calls[1][1..]
  end

  test "string primary keys stay strings and two calls return the same cut" do
    holder = role("Keeper", LEDGER_KEY)
    scope_grant(@alice, holder, Ledger.create!(code: "M-9", name: "Later"))
    scope_grant(@alice, holder, Ledger.create!(code: "ACME-001", name: "Middle"))
    scope_grant(@alice, holder, Ledger.create!(code: "200", name: "First"))

    first = CurrentScope.abilities_for(@alice, scopes: [ [ Ledger, LEDGER_KEY ] ], limit: 2)
    second = CurrentScope.abilities_for(@alice, scopes: [ [ Ledger, LEDGER_KEY ] ], limit: 2)
    entry = first[:scoped].sole

    assert_equal second[:scoped], first[:scoped]
    assert_equal [ "200", "ACME-001" ], entry[:ids]
    assert_equal true, entry[:truncated]
    assert entry[:ids].all? { |id| id.is_a?(String) }
    assert_equal listed_ids(@alice, Ledger, LEDGER_KEY).first(2), entry[:ids]
  end

  test "a bad scope list raises before scope_for runs" do
    bad_lists = [
      nil,
      "projects",
      [ Project, PROJECT_KEY ],
      [ [ "Project", PROJECT_KEY ] ],
      [ [ Project, :index ] ],
      [ [ Project, "" ] ]
    ]

    bad_lists.each do |scopes|
      calls = scope_calls do
        assert_no_queries do
          assert_raises(ArgumentError) do
            CurrentScope.abilities_for(@alice, scopes: scopes, limit: 2)
          end
        end
      end
      assert_empty calls, "scopes #{scopes.inspect} must not call scope_for"
    end
  end
end
