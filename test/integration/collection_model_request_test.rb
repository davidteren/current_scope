require "test_helper"

# #50, end to end: the record-less type bind reproduced through real requests.
# Before this fix a scoped grant of ANY type opened every record-less gate —
# harmless-looking on #index (an empty list), a live escalation on #create.
# These pin that a grant on type A never opens type B's collection gate, and
# that a same-type grant still does.
class CollectionModelRequestTest < ActionDispatch::IntegrationTest
  setup do
    @alice = User.create!(name: "Alice")
    @bob = User.create!(name: "Bob")
    @report = Report.create!(title: "Q3", requested_by: @bob)
  end

  def sign_in(user) = { "X-User-Id" => user.id.to_s }

  def role(name, *keys)
    r = CurrentScope::Role.create!(name: name)
    keys.each { |k| r.role_permissions.create!(permission_key: k) }
    r
  end

  def scope_grant(user, role, record)
    CurrentScope::ScopedRoleAssignment.create!(subject: user, role: role, resource: record)
  end

  test "a Report-scoped subject is denied the Projects index (was a silent 200)" do
    # Alice holds only a scoped grant on a Report, under a role ticking
    # projects#index. The gate lists Projects; her grant is on a Report.
    scope_grant(@alice, role("Cross", "projects#index"), @report)

    get projects_url, headers: sign_in(@alice)
    assert_response :forbidden,
      "a grant on a Report must not open the Projects collection gate"
  end

  test "a Report-scoped subject is denied Projects create — the escalation with no list side" do
    scope_grant(@alice, role("Cross", "projects#create"), @report)

    post projects_url, headers: sign_in(@alice)
    assert_response :forbidden,
      "the #create escalation: a Report grant must not create a Project"
  end

  test "a Project-scoped subject reaches the Projects index, narrowed to their rows" do
    mine = Project.create!(name: "Mine")
    Project.create!(name: "Theirs") # never granted
    scope_grant(@alice, role("Editor", "projects#index"), mine)

    get projects_url, headers: sign_in(@alice)
    assert_response :success, "a same-type scoped grant opens the gate"
    assert_equal "Mine", response.body
    assert_no_match(/Theirs/, response.body, "scope_for narrows to the granted row")
  end

  test "an Invoice-scoped subject reaches the Documents index (STI base_class, R6)" do
    invoice = Invoice.create!(title: "INV-1")
    scope_grant(@alice, role("Editor", "documents#index"), invoice)

    get documents_url, headers: sign_in(@alice)
    assert_response :success,
      "a grant on an Invoice (base_class Document) must open the Documents gate"
    assert_equal "INV-1", response.body
  end

  test "U6: the view agrees with the gate — allowed_to?(:index) is true where the gate would allow index" do
    # The regression U6 exists for: after U2 a bare allowed_to?(:index) would
    # return false on a DECLARED controller, hiding a link the gate allows. The
    # advisory action (reached via a grant ticking projects#advisory) renders
    # allowed_to?(:index); it must say true because the SAME scoped grant ticks
    # projects#index, exactly what a real GET /projects would honor.
    mine = Project.create!(name: "Mine")
    scope_grant(@alice, role("Editor", "projects#index", "projects#advisory"), mine)

    get "/projects_advisory", headers: sign_in(@alice)
    assert_response :success, "the advisory grant opens the advisory gate"
    assert_equal "true", response.body,
      "allowed_to?(:index) binds the ambient Project type and agrees with the index gate"
  end

  test "U6: the view agrees with the gate in the deny direction too" do
    # The grant ticks advisory (so the action is reachable) but NOT index —
    # allowed_to?(:index) must therefore be false, not a stale true.
    mine = Project.create!(name: "Mine")
    scope_grant(@alice, role("AdvisoryOnly", "projects#advisory"), mine)

    get "/projects_advisory", headers: sign_in(@alice)
    assert_response :success
    assert_equal "false", response.body,
      "no projects#index tick ⇒ the advisory answer is false, matching the index gate"
  end

  test "U6: an inert-model controller stashes no ambient type — the view can't diverge from the gate" do
    # InertModelController declares current_scope_model but no
    # current_scope_record. The gate passes NO_RECORD and denies a scoped
    # subject; a full-access subject reaches #ambient, which renders the stashed
    # type. It must be nil — stashing Report there would let a view show a link
    # the gate 403s (#50 review, cubic).
    owner = User.create!(name: "Owner")
    CurrentScope::RoleAssignment.create!(
      subject: owner, role: CurrentScope::Role.create!(name: "Owner", full_access: true))

    get "/inert_model_ambient", headers: sign_in(owner)
    assert_response :success
    assert_equal "nil", response.body,
      "the Guard must not stash the ambient model when the record hook is absent"
  end

  test "nested_reports#index still reaches a Report-scoped subject, key drift and all" do
    project = Project.create!(name: "P")
    scope_grant(@alice, role("Viewer", "nested_reports#index"), @report)

    get project_nested_reports_url(project), headers: sign_in(@alice)
    assert_response :success,
      "the hook binds the gate by type; the controller still hands scope_for its own key"
    assert_equal "Q3", response.body
  end
end
