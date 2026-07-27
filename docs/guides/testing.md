# Testing your app

> See also: [Concepts & glossary](concepts-and-glossary.md).

## Testing your app

```ruby
require "current_scope/test_helpers"

class ApproveButtonComponentTest < ViewComponent::TestCase
  include CurrentScope::TestHelpers

  test "renders for a reviewer" do
    with_current_user(users(:reviewer)) do
      render_inline ApproveButtonComponent.new(report: reports(:pending))
      assert_selector "button", text: "Approve"
    end
  end
end
```

`with_current_user` is for in-process unit/view/component checks. To test your
own controllers **behind the gate** in a request or system spec, seed real
grants with `grant_role!` / `grant_scoped_role!` — they persist assignment rows
that survive the request cycle (which `with_current_user` cannot, since
`Context` re-resolves the subject on every real request). They seed grants only;
your app still signs the subject in through its own auth. A second org-wide
`grant_role!` for the same subject raises (one org role per subject) and names
`CurrentScope.grant!` for replace or scoped roles for additive access:

```ruby
class ReportsAccessTest < ActionDispatch::IntegrationTest
  include CurrentScope::TestHelpers

  test "a reviewer can list but not destroy" do
    reviewer = users(:reviewer)
    grant_role!(reviewer, role: roles(:member))              # org-wide grant
    grant_scoped_role!(reviewer, role: roles(:viewer), record: reports(:q3))  # one record

    sign_in reviewer            # your app's own auth
    get reports_path
    assert_response :success

    # Assert the denial too — a test that only walks the allow path cannot
    # tell you the gate is still closed on everything else.
    delete report_path(reports(:q3))
    assert_response :forbidden
  end
end
```

`CurrentAttributes` resets around every request, job, and test — the ambient
subject cannot leak between executions.
