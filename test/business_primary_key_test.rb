require "test_helper"

# #150. A model whose declared primary key is not the `id` column, while a
# leftover surrogate `id` still exists. A grant on Alpha (code "200") must not
# open Beta (id 200).
class BusinessPrimaryKeyTest < ActiveSupport::TestCase
  setup do
    @resolver = CurrentScope::Resolver.new
    @role = CurrentScope::Role.create!(name: "Lead")
    @role.role_permissions.create!(permission_key: "folders#show")
    @holder = User.create!(name: "Lead")
    @alpha = Ledger.create!(code: "200", name: "Alpha")
  end

  def insert_beta!
    now = Time.current.to_fs(:db)
    Ledger.connection.execute(
      Ledger.sanitize_sql([
        "INSERT INTO ledgers (id, code, name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
        200, "999", "Beta", now, now
      ])
    )
    Ledger.find("999")
  end

  test "a grant on Alpha does not open Beta whose surrogate id equals Alpha's code" do
    beta = insert_beta!
    grant = CurrentScope::ScopedRoleAssignment.create!(
      subject: @holder, role: @role, resource: @alpha
    )

    assert_equal "200", grant.resource_id
    assert_equal 1, @alpha.class.connection.select_value(
      Ledger.sanitize_sql([ "SELECT id FROM ledgers WHERE code = ?", "200" ])
    )
    assert_equal 200, @alpha.class.connection.select_value(
      Ledger.sanitize_sql([ "SELECT id FROM ledgers WHERE code = ?", "999" ])
    )

    assert_equal [ true, nil ],
                 @resolver.decide(subject: @holder, permission: "folders#show", record: @alpha)
    assert_equal [ false, :no_grant ],
                 @resolver.decide(subject: @holder, permission: "folders#show", record: beta)

    listed = @resolver.scope_for(subject: @holder, model: Ledger, permission: "folders#show")
    assert_equal [ "200" ], listed.map(&:code)
  end

  test "a non-numeric business key stores whole and matches only that row" do
    acme = Ledger.create!(code: "ACME-001", name: "Acme")
    grant = CurrentScope::ScopedRoleAssignment.create!(
      subject: @holder, role: @role, resource: acme
    )

    assert_equal "ACME-001", grant.resource_id
    assert_equal [ true, nil ],
                 @resolver.decide(subject: @holder, permission: "folders#show", record: acme)
    assert_equal [ false, :no_grant ],
                 @resolver.decide(subject: @holder, permission: "folders#show", record: @alpha)
  end

  test "the preloader and checked reader see a business-key grant as live" do
    grant = CurrentScope::ScopedRoleAssignment.create!(
      subject: @holder, role: @role, resource: @alpha
    )

    CurrentScope::ScopedRoleAssignment.preload_resolvable_resources!([ grant ])
    assert_not grant.orphaned_resource?
    assert_equal @alpha, grant.current_scope_resolved_record("resource")
  end

  test "a parent-chain grant on Alpha lists Alpha's entries, not Beta's" do
    beta = insert_beta!
    alpha_entry = Entry.create!(title: "Alpha row", ledger: @alpha)
    beta_entry = Entry.create!(title: "Beta row", ledger: beta)
    CurrentScope::ScopedRoleAssignment.create!(
      subject: @holder, role: @role, resource: @alpha
    )

    assert_nothing_raised do
      CurrentScope::ParentChain.send(:validate_key!, Entry, Entry.reflect_on_association(:ledger))
    end

    listed = @resolver.scope_for(subject: @holder, model: Entry, permission: "folders#show")
    assert_includes listed, alpha_entry
    assert_not_includes listed, beta_entry
    assert_equal [ true, nil ],
                 @resolver.decide(subject: @holder, permission: "folders#show", record: alpha_entry)
    assert_equal [ false, :no_grant ],
                 @resolver.decide(subject: @holder, permission: "folders#show", record: beta_entry)
  end

  test "id-keyed parents are still accepted by validate_key!" do
    assert_nothing_raised do
      CurrentScope::ParentChain.send(:validate_key!, Report, Report.reflect_on_association(:project))
    end
    assert_nothing_raised { CurrentScope::ParentChain.validate_declarations! }
  end
end
