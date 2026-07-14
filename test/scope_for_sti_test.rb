require "test_helper"

# A7: scope_for must query the polymorphic base_class, not the passed model's
# name. A scoped grant on an STI subclass (Invoice) stores resource_type =
# "Document" (the base_class), so scope_for(Invoice) querying "Invoice" returns
# nothing while the per-record gate would allow it. The two must agree.
class ScopeForStiTest < ActiveSupport::TestCase
  setup do
    @resolver = CurrentScope::Resolver.new
    @user = User.create!(name: "Manager")
    @invoice = Invoice.create!(title: "INV-1")
    @role = CurrentScope::Role.create!(name: "InvoiceViewer")
    @role.role_permissions.create!(permission_key: "invoices#index")
    CurrentScope::ScopedRoleAssignment.create!(subject: @user, role: @role, resource: @invoice)
  end

  test "scope_for(STI subclass) includes the granted record" do
    result = @resolver.scope_for(subject: @user, model: Invoice, permission: "invoices#index")
    assert_includes result, @invoice
  end

  test "scope_for agrees with the per-record gate for the STI subclass" do
    result = @resolver.scope_for(subject: @user, model: Invoice, permission: "invoices#index")
    # Every record scope_for returns must pass the per-record gate, and vice versa.
    assert @resolver.allow?(subject: @user, permission: "invoices#index", record: @invoice)
    assert_equal [ @invoice ], result.to_a
  end

  test "an ungranted subject sees none (fail-closed, unchanged)" do
    stranger = User.create!(name: "Stranger")
    result = @resolver.scope_for(subject: stranger, model: Invoice, permission: "invoices#index")
    assert_empty result
  end
end
