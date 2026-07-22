require "test_helper"

class AccessDeniedTest < ActiveSupport::TestCase
  test "permission defaults to the positional message for backward compatibility" do
    e = CurrentScope::AccessDenied.new("posts#index", reason: :no_grant)

    assert_equal "posts#index", e.message
    assert_equal "posts#index", e.permission
    assert_equal :no_grant, e.reason
    assert_nil e.record
    assert_nil e.subject
  end

  test "permission, record, and subject are first-class and independent of message" do
    user = User.create!(name: "Ada")
    report = Report.create!(title: "Q3", requested_by: user)

    e = CurrentScope::AccessDenied.new(
      "legacy-message",
      reason: :no_grant,
      permission: "reports#approve",
      record: report,
      subject: user
    )

    assert_equal "legacy-message", e.message
    assert_equal "reports#approve", e.permission
    assert_equal :no_grant, e.reason
    assert_equal report, e.record
    assert_equal user, e.subject
  end

  test "explicit nil record is preserved (gate denials load no record)" do
    user = User.create!(name: "Bob")
    e = CurrentScope::AccessDenied.new(
      "reports#approve",
      reason: :impersonation_gate,
      permission: "reports#approve",
      record: nil,
      subject: user
    )

    assert_nil e.record
    assert_equal user, e.subject
    assert_equal :impersonation_gate, e.reason
  end
end
