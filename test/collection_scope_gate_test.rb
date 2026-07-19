require "test_helper"

# The record-less half of the per-record feature: a collection gate (#index and
# friends) reaches the resolver with `record: nil`, and a class-form check
# (allowed_to?(:index, Report)) reaches it with a Class. Neither can carry a
# scoped grant, so a scoped-only subject used to be turned away from the very
# list scope_for exists to narrow — and the org-wide grant that got them past
# the gate made scope_for return every record. This suite pins the rule: for a
# record-less target of a known type, an action in collection_read_actions
# answers via the id-narrowed scope_for query (so gate and list agree by
# construction, full_access included — #65), any other action needs a scoped
# grant whose role EXPLICITLY ticks the key, and every persisted-record
# decision stays byte-for-byte unchanged (the load-bearing assertions below).
class CollectionScopeGateTest < ActiveSupport::TestCase
  setup do
    @resolver = CurrentScope::Resolver.new
    @alice = User.create!(name: "Alice")
    @bob = User.create!(name: "Bob")
    @report = Report.create!(title: "Q3", requested_by: @bob)
    @other = Report.create!(title: "Q4", requested_by: @bob)
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

  # --- R1/R3: a scoped grant opens the record-less gate ---

  test "a scoped grant whose role ticks the key opens a nil-record collection gate" do
    scope_grant(@alice, role("Editor", "reports#index"), @report)

    # Since #50 the nil-record gate binds by the declared type — the Guard
    # threads model: from current_scope_model. The grant is on a Report, so a
    # Report gate opens; scope_for then narrows the list.
    allowed, reason = @resolver.decide(subject: @alice, permission: "reports#index", record: nil, model: Report)
    assert allowed, "a scoped-only subject must reach the list scope_for exists to narrow"
    assert_nil reason, "an ordinary grant carries no reason — it is not an audited exception"
  end

  test "a scoped grant whose role ticks the key opens a class-form check" do
    scope_grant(@alice, role("Editor", "reports#index"), @report)

    assert @resolver.allow?(subject: @alice, permission: "reports#index", record: Report),
      "the view helper and the gate must never disagree"
  end

  # Since #65 a scoped full_access role opens LISTED READS of its own type —
  # the gate derives from the id-narrowed scope_for query, so it opens exactly
  # the collections that would show the record. Everything else stays barred:
  # a full_access role satisfies every key, so any record-less check that
  # answers with a boolean off an unbound (or merely type-bound) match would
  # turn one scoped grant on one record into a pass on every #create in the
  # host app. That is reachable with stock data: seed_defaults! ships a
  # full_access "Owner" role and the scoped picker offers every role.
  test "a scoped full_access role opens only listed reads of its own type — never writes, never app-wide" do
    scope_grant(@alice, role("Owner", full_access: true), @report)

    # No declared type ⇒ every record-less check stays shut (fail-closed, #50).
    %w[reports#index reports#create projects#index documents#create widgets#anything].each do |key|
      assert_not @resolver.allow?(subject: @alice, permission: key, record: nil),
        "no declared type ⇒ #{key} stays shut"
    end

    # The class form carries the type. Listed reads open off the id-narrowed
    # list — another controller's key included, because for a full_access
    # grant scope_for's answer turns on the type and record liveness, not the
    # key's controller: that gate's list would show her the Report too.
    assert @resolver.allow?(subject: @alice, permission: "reports#index", record: Report)
    assert @resolver.allow?(subject: @alice, permission: "projects#index", record: Report)

    # Keys with no list side stay barred off full_access — the #49/#65
    # escalation line: one grant on one Report must not create Reports,
    # create Documents, or touch another type's gates.
    %w[reports#create documents#create widgets#anything].each do |key|
      assert_not @resolver.allow?(subject: @alice, permission: key, record: Report),
        "#{key} has no list side — a scoped full_access grant must not open it"
    end
    assert_not @resolver.allow?(subject: @alice, permission: "documents#index", record: Document),
      "a Report grant opens nothing of another type, listed read or not"
  end

  # --- #50: the record-less branch binds by the declared TYPE ---

  test "consequence 1 CLOSED: a Report grant never opens a Documents record-less gate" do
    # The escalation, inverted. Alice holds only a scoped grant on a Report,
    # under a role ticking documents#create. Before #50 the unbound branch let
    # her create Documents — a key with no list side to save it.
    scope_grant(@alice, role("Editor", "documents#create", "documents#index"), @report)

    assert_not @resolver.allow?(subject: @alice, permission: "documents#create", record: nil, model: Document),
      "a grant on a Report must not open a Documents #create gate"
    assert_not @resolver.allow?(subject: @alice, permission: "documents#index", record: nil, model: Document),
      "nor a Documents #index gate"
    # And the class form of the same cross-type question.
    assert_not @resolver.allow?(subject: @alice, permission: "documents#create", record: Document)
  end

  test "#19 preserved for a declared controller: a same-type grant opens the gate" do
    scope_grant(@alice, role("Editor", "reports#index"), @report)

    assert @resolver.allow?(subject: @alice, permission: "reports#index", record: nil, model: Report),
      "the grant is on a Report and the gate lists Reports — it opens"
  end

  test "R3 fail-closed: an unknown type never fires the record-less branch" do
    scope_grant(@alice, role("Editor", "reports#index"), @report)

    assert_not @resolver.allow?(subject: @alice, permission: "reports#index", record: nil, model: nil),
      "no declared type ⇒ the branch does not fire; deny is the honest answer"
  end

  test "#65 closed: scoped full_access opens its own type's listed read, derived from the scoped list" do
    # 029's R4 was withdrawn because a type-bound BOOLEAN cannot honor
    # full_access safely. This is not that: the gate asks scope_for, whose
    # answer is derived from the record ids the subject actually holds — the
    # one shape the roles_granting safety condition names as safe.
    scope_grant(@alice, role("Owner", full_access: true), @report)

    assert @resolver.allow?(subject: @alice, permission: "reports#index", record: nil, model: Report),
      "the list would show her Report — the gate derives from the same id-narrowed query and agrees"
  end

  test "the P0 stays shut with a type in hand: full_access on Report never opens Documents" do
    scope_grant(@alice, role("Owner", full_access: true), @report)

    assert_not @resolver.allow?(subject: @alice, permission: "documents#index", record: nil, model: Document),
      "one scoped full_access grant on a Report must not open another type's gate"
  end

  test "R5 class form binds from its argument, matching type only" do
    scope_grant(@alice, role("Editor", "reports#index"), @report)

    assert @resolver.allow?(subject: @alice, permission: "reports#index", record: Report),
      "the class form carries the type — a Report-scoped grant opens the Report class form"
    assert_not @resolver.allow?(subject: @alice, permission: "reports#index", record: Document),
      "and does not open the Document class form"
  end

  test "R6 STI: a grant on a subclass binds through base_class, not the subclass name" do
    invoice = Invoice.create!(title: "INV-1")
    scope_grant(@alice, role("Editor", "documents#index"), invoice)

    # The grant stores resource_type "Document" (base_class). Both the subclass
    # and the base as the declared model must open the gate — asserting
    # model.name would fail on Invoice, which is exactly R6's point.
    assert @resolver.allow?(subject: @alice, permission: "documents#index", record: nil, model: Invoice),
      "model: Invoice normalizes to Document and matches the stored grant"
    assert @resolver.allow?(subject: @alice, permission: "documents#index", record: nil, model: Document),
      "model: Document matches the same stored grant"
  end

  test "R6a ceiling: within one base_class, STI siblings collapse (accepted)" do
    # An Invoice-scoped grant opens a gate declared with model: Document
    # because both normalize to Document. This is the deliberate within-base-
    # class collapse (Risks) — the branch has no STI type predicate the way
    # scope_for's model.where(...) does. Pinned as accepted, not a bug.
    invoice = Invoice.create!(title: "INV-1")
    scope_grant(@alice, role("Editor", "documents#index"), invoice)

    assert @resolver.allow?(subject: @alice, permission: "documents#index", record: nil, model: Document),
      "sibling collapse within a base_class is the accepted ceiling (Risks)"
  end

  test "a non-ActiveRecord type fails CLOSED, never crashes — the record hook's guard, mirrored for model" do
    scope_grant(@alice, role("Editor", "reports#index"), @report)

    # A mis-declared current_scope_model (String/Symbol/instance) or a non-AR
    # class passed to the class form has no base_class. Each must deny, not
    # raise NoMethodError. (#50 review)
    [ "Report", :Report, Object.new, 42 ].each do |bad|
      assert_not @resolver.allow?(subject: @alice, permission: "reports#index", record: nil, model: bad),
        "a #{bad.class} model must fail closed, not crash"
    end
    # The class form with a non-AR class (the gem ships a Scopeable PORO,
    # Gadget) previously returned a boolean; it must still deny, not crash.
    assert_not @resolver.allow?(subject: @alice, permission: "reports#index", record: Gadget),
      "a non-ActiveRecord class form must fail closed, not crash"
    assert_not @resolver.allow?(subject: @alice, permission: "reports#index", record: Object)
  end

  test "resolver purity: model: is a parameter, never state" do
    scope_grant(@alice, role("Editor", "reports#index"), @report)

    # Two decides with different models must not interfere — no per-decision
    # state leaks between them.
    a = @resolver.allow?(subject: @alice, permission: "reports#index", record: nil, model: Report)
    b = @resolver.allow?(subject: @alice, permission: "reports#index", record: nil, model: Document)
    assert a, "the Report model opens the Report grant"
    assert_not b, "the Document model does not — and the prior call left no residue"
    assert @resolver.allow?(subject: @alice, permission: "reports#index", record: nil, model: Report),
      "repeating the first call still allows — order-independent"
  end

  # A role can be full_access AND carry explicit rows — tick grid cells, then
  # flip the full-access toggle. On the write side, matching on the leftover
  # row would walk it right back through the branch full_access is barred from.
  test "a scoped full_access role with explicit rows follows the same read-only rule" do
    owner = role("Owner", "reports#index", full_access: true)
    scope_grant(@alice, owner, @report)

    assert_not @resolver.allow?(subject: @alice, permission: "reports#index", record: nil),
      "no declared type ⇒ shut, leftover row or not"
    # A listed read of her own type opens off the id-narrowed list (#65) —
    # both the leftover row and the wildcard legitimately match there.
    assert @resolver.allow?(subject: @alice, permission: "reports#index", record: Report)
    # ...and the leftover row must not smuggle the role past the write-side bar.
    assert_not @resolver.allow?(subject: @alice, permission: "reports#create", record: Report),
      "the explicit row must not walk a full_access role through the non-read branch"

    # Unchanged where it is bound to a record: full_access still means full
    # access to the record it was granted on.
    assert @resolver.allow?(subject: @alice, permission: "reports#index", record: @report)
  end

  test "a scoped full_access role still grants everything on its OWN record" do
    scope_grant(@alice, role("Owner", full_access: true), @report)

    # The per-record half is untouched — scoped_grant? binds by `resource:`, so
    # full_access is safe to wildcard there. This is what the grant means.
    assert @resolver.allow?(subject: @alice, permission: "reports#destroy", record: @report)
    assert_not @resolver.allow?(subject: @alice, permission: "reports#destroy", record: @other)
  end

  # --- R4: still fail-closed ---

  test "a scoped role that does not tick the key leaves the record-less gate shut" do
    scope_grant(@alice, role("Viewer", "reports#show"), @report) # no reports#index

    allowed, reason = @resolver.decide(subject: @alice, permission: "reports#index", record: nil)
    assert_not allowed
    assert_equal :no_grant, reason
  end

  test "a scoped role that does not tick the key leaves the class-form check shut" do
    scope_grant(@alice, role("Viewer", "reports#show"), @report)

    assert_not @resolver.allow?(subject: @alice, permission: "reports#index", record: Report)
  end

  test "no grants at all still denies a record-less target (fail closed)" do
    allowed, reason = @resolver.decide(subject: @alice, permission: "reports#index", record: nil)
    assert_not allowed
    assert_equal :no_grant, reason
  end

  test "a nil subject still denies a record-less target (fail closed)" do
    assert_not @resolver.allow?(subject: nil, permission: "reports#index", record: nil)
  end

  test "another subject's scoped grant does not open this subject's gate" do
    scope_grant(@bob, role("Editor", "reports#index"), @report)

    assert_not @resolver.allow?(subject: @alice, permission: "reports#index", record: nil)
  end

  # --- R5: persisted-record decisions are unchanged (the anti-regression set) ---

  test "R5: a scoped grant on X still grants nothing on sibling Y" do
    scope_grant(@alice, role("Editor", "reports#show"), @report)

    assert @resolver.allow?(subject: @alice, permission: "reports#show", record: @report),
      "the grant on X still works via the untouched scoped_grant? path"
    assert_not @resolver.allow?(subject: @alice, permission: "reports#show", record: @other),
      "the record-less branch must NEVER fire for a persisted instance"
  end

  test "R5: a scoped grant on X does not open an unticked key on X" do
    scope_grant(@alice, role("Editor", "reports#show"), @report)

    assert_not @resolver.allow?(subject: @alice, permission: "reports#destroy", record: @report)
  end

  test "R5: an unpersisted instance is not a record-less target" do
    scope_grant(@alice, role("Editor", "reports#create"), @report)

    # Report.new is neither nil nor a Class, so the record-less branch skips it,
    # and scoped_grant? needs persisted? — denied. Only reachable by gating a
    # collection action with Model.new instead of the documented nil, and it
    # fails closed. Pinned so the branch can't widen to instances.
    assert_not @resolver.allow?(subject: @alice, permission: "reports#create", record: Report.new)
  end

  # The record-less test is POSITIVE (nil or a Class) precisely so these fail
  # closed. A negative `unless record.respond_to?(:new_record?)` admits an open
  # set: a host whose current_scope_record wrongly returns params[:id] would
  # hand a String to the gate and be ALLOWED here on the strength of a grant
  # held over some OTHER record — privilege escalation, and the exact inversion
  # of "a grant on X must not act on Y".
  test "R5: a non-record target fails CLOSED, never open" do
    # Alice is scoped on @report ONLY, and holds no org grant.
    scope_grant(@alice, role("Editor", "reports#show"), @report)

    [ @other.id.to_s, @other.id, :garbage, "anything", 42, {}, [], Object.new ].each do |target|
      assert_not @resolver.allow?(subject: @alice, permission: "reports#show", record: target),
        "a #{target.class} target must never be treated as record-less — it would grant " \
        "access off a scoped grant held over a different record"
    end
  end

  test "R5: a non-record target is denied even when it names a granted record" do
    scope_grant(@alice, role("Editor", "reports#show"), @report)

    # Naming the very record she IS scoped on must not help either — the gate
    # decides on records, not on strings that look like ids.
    assert_not @resolver.allow?(subject: @alice, permission: "reports#show", record: @report.id.to_s)
  end

  test "R5: the SoD veto still runs upstream of the record-less branch" do
    original = CurrentScope.config.sod_actions
    CurrentScope.config.sod_actions = %w[approve]
    # Bob initiated @report AND holds a scoped grant on it that ticks approve.
    scope_grant(@bob, role("Reviewer", "reports#approve"), @report)

    allowed, reason = @resolver.decide(subject: @bob, permission: "reports#approve", record: @report)
    assert_not allowed, "the veto must still beat a scoped grant on a persisted record"
    assert_equal :sod_veto, reason
  ensure
    CurrentScope.config.sod_actions = original
  end

  # --- Ordering: the pre-existing allow paths win before the new branch ---

  test "an org-wide grant is unchanged and resolves before the new branch" do
    assign(@alice, role("Member", "reports#index"))

    assert @resolver.allow?(subject: @alice, permission: "reports#index", record: nil)
  end

  test "full_access is unchanged" do
    assign(@alice, role("Owner", full_access: true))

    assert @resolver.allow?(subject: @alice, permission: "reports#index", record: nil)
  end

  # --- KTD-3 / OQ-2: the branch is uniform across record-less targets ---

  test "OQ-2: a scoped role that ticks a collection key opens that gate too" do
    # Accepted consequence of the uniform record-less rule (KTD-3): identical to
    # how an org grant of `create` already behaves, and there is no record filter
    # on create regardless. Pinned so a change here is a deliberate decision.
    scope_grant(@alice, role("Editor", "reports#create"), @report)

    assert @resolver.allow?(subject: @alice, permission: "reports#create", record: nil, model: Report)
  end

  # An SoD action is record-targeted by definition, so a record-less SoD check is
  # a contradiction — there is no record for the veto to measure. The branch
  # refuses rather than handing out a four-eyes action with the veto skipped,
  # which is what a host mis-gating `reports#approve` with a nil record would
  # otherwise get. The veto is a structural guarantee; it must not depend on an
  # opt-in dev warning.
  test "a record-less SoD action is never opened by a scoped grant" do
    original = CurrentScope.config.sod_actions
    CurrentScope.config.sod_actions = %w[approve]
    scope_grant(@alice, role("Reviewer", "reports#approve"), @report) # alice did NOT initiate it

    [ nil, Report ].each do |target|
      allowed, reason = @resolver.decide(subject: @alice, permission: "reports#approve", record: target)
      assert_not allowed, "a record-less SoD target (#{target.inspect}) must not be opened by a scoped grant"
      assert_equal :no_grant, reason
    end

    # The same grant still works where SoD can actually be evaluated.
    assert @resolver.allow?(subject: @alice, permission: "reports#approve", record: @report)
  ensure
    CurrentScope.config.sod_actions = original
  end

  test "the SoD exclusion tracks config, not a hardcoded action list" do
    original = CurrentScope.config.sod_actions
    CurrentScope.config.sod_actions = []
    scope_grant(@alice, role("Reviewer", "reports#approve"), @report)

    # approve is not an SoD action here, so it is an ordinary collection key.
    assert @resolver.allow?(subject: @alice, permission: "reports#approve", record: nil, model: Report)
  ensure
    CurrentScope.config.sod_actions = original
  end

  # --- R7a (#50 U3): the :model_undeclared LABEL on the undeclared-type deny ---
  #
  # A record-less deny for want of a type was indistinguishable from an
  # ordinary :no_grant — and the dev nudge is dev/test-only, so the production
  # host who most needs the cause could never see it. The label rides
  # X-Current-Scope-Reason. It changes no decision: every case below was
  # already a deny, only the reason differs.

  test "R7a: the undeclared-type deny with a ticking grant is labelled :model_undeclared" do
    scope_grant(@alice, role("Editor", "reports#index"), @report)

    allowed, reason = @resolver.decide(subject: @alice, permission: "reports#index", record: nil, model: nil)
    assert_not allowed, "the label must not change the decision — still a deny"
    assert_equal :model_undeclared, reason,
      "the deny would have been an ALLOW had the type been declared — say so"
  end

  test "R7a: no ticking grant means an ordinary :no_grant, not :model_undeclared" do
    allowed, reason = @resolver.decide(subject: @alice, permission: "reports#index", record: nil, model: nil)
    assert_not allowed
    assert_equal :no_grant, reason,
      "with nothing granted, declaring a model would change nothing — the label would lie"
  end

  test "R7a widened (#65): a scoped full_access grant on a LISTED read is :model_undeclared" do
    # Since #65 a declared model WOULD honor full_access on a listed read (the
    # scope_for-derived branch), so the label is honest here — with the caveat
    # its nudge wording already carries: the predicate runs without a model
    # and cannot check record liveness, so it says "may fix", never promises.
    scope_grant(@alice, role("Owner", full_access: true), @report)

    allowed, reason = @resolver.decide(subject: @alice, permission: "reports#index", record: nil, model: nil)
    assert_not allowed, "the label must not change the decision — still a deny"
    assert_equal :model_undeclared, reason
  end

  test "R7a unchanged off the read list: a full_access-only grant on create stays :no_grant" do
    # The original #65 tripwire, now scoped to where it still holds: declaring
    # a model would NOT open create off full_access (that branch keeps
    # roles_ticking), so labelling it :model_undeclared would send the host to
    # a fix that fixes nothing. A roles_granting swap there turns this red.
    scope_grant(@alice, role("Owner", full_access: true), @report)

    allowed, reason = @resolver.decide(subject: @alice, permission: "reports#create", record: nil, model: nil)
    assert_not allowed
    assert_equal :no_grant, reason
  end

  test "R7a: the class form always carries its type, so it is never :model_undeclared" do
    scope_grant(@alice, role("Editor", "reports#index"), @report)

    allowed, reason = @resolver.decide(subject: @alice, permission: "reports#index", record: Document, model: nil)
    assert_not allowed, "the grant is on a Report; the Document class form stays shut"
    assert_equal :no_grant, reason, "the type was known and simply did not match — nothing undeclared"
  end

  test "R7a: a record-less SoD deny is never :model_undeclared" do
    original = CurrentScope.config.sod_actions
    CurrentScope.config.sod_actions = %w[approve]
    scope_grant(@alice, role("Reviewer", "reports#approve"), @report)

    allowed, reason = @resolver.decide(subject: @alice, permission: "reports#approve", record: nil, model: nil)
    assert_not allowed
    assert_equal :no_grant, reason,
      "a record-less SoD target is refused whatever the type — a model hook would not fix it"
  ensure
    CurrentScope.config.sod_actions = original
  end

  test "R7a: a declared model keeps its denies as :no_grant — nothing is undeclared" do
    scope_grant(@alice, role("Editor", "documents#index"), @report) # Report grant, Documents gate

    allowed, reason = @resolver.decide(subject: @alice, permission: "documents#index", record: nil, model: Document)
    assert_not allowed
    assert_equal :no_grant, reason
  end

  # --- :model_invalid (0.3.0 release gate): declared-but-unusable types get their own label ---
  #
  # A declared current_scope_model the shape guard refuses (String, instance,
  # PORO, abstract class) used to deny as plain :no_grant — byte-identical to
  # "never granted", pointing nowhere near the bad declaration. Same cell as
  # :model_undeclared, different fix, so a different label. Still label-only:
  # every case below was already a deny.

  test "a declared-but-invalid model with a ticking grant is :model_invalid, not :no_grant" do
    scope_grant(@alice, role("Editor", "reports#index"), @report)

    [ "Report", :Report, Report.new, Struct.new(:id) ].each do |bad_type|
      allowed, reason = @resolver.decide(subject: @alice, permission: "reports#index", record: nil, model: bad_type)
      assert_not allowed, "#{bad_type.inspect} must not open the gate — the label changes no decision"
      assert_equal :model_invalid, reason,
        "#{bad_type.inspect} was declared and refused — say so, not :no_grant"
    end
  end

  test "an ABSTRACT declared model is :model_invalid too" do
    scope_grant(@alice, role("Editor", "reports#index"), @report)

    allowed, reason = @resolver.decide(subject: @alice, permission: "reports#index", record: nil, model: ApplicationRecord)
    assert_not allowed
    assert_equal :model_invalid, reason,
      "abstract classes store no rows — refused by the same shape guard, same label"
  end

  test ":model_invalid needs a grant, like :model_undeclared — otherwise plain :no_grant" do
    allowed, reason = @resolver.decide(subject: @alice, permission: "reports#index", record: nil, model: "Report")
    assert_not allowed
    assert_equal :no_grant, reason,
      "with nothing granted, fixing the declaration would change nothing — the label would lie"
  end

  test "the class form stays :no_grant for a non-AR argument — nothing was declared" do
    # allowed_to?(:index, SomePORO) carries its type as the RECORD, so it
    # never lands in the declared-model cell; the pre-#50 boolean contract
    # (plain false) holds and the label stays out of it.
    scope_grant(@alice, role("Editor", "reports#index"), @report)

    allowed, reason = @resolver.decide(subject: @alice, permission: "reports#index", record: Struct.new(:id), model: nil)
    assert_not allowed
    assert_equal :no_grant, reason
  end

  # --- #65: listed collection reads derive from the scoped list ---
  #
  # The gate asks scope_for(...).exists? — the same id-narrowed query the list
  # renders from — so for these actions "the gate let them in" and "it is in
  # their list" are one claim, by construction. The pins below are the durable
  # tripwire the issue asks for: they discriminate a respell back to any
  # boolean-permit form (assignment-level EXISTS/any?/count over a
  # full_access-inclusive set), which is #49's escalation shape.

  test "AE1 (#65): gate and list agree — the full_access owner opens reports#index and sees exactly her record" do
    scope_grant(@alice, role("Owner", full_access: true), @report)

    assert @resolver.allow?(subject: @alice, permission: "reports#index", record: nil, model: Report)
    assert @resolver.allow?(subject: @alice, permission: "reports#index", record: Report),
      "the class form binds the same type and must agree with the gate"
    assert_equal [ @report.id ],
      @resolver.scope_for(subject: @alice, model: Report, permission: "reports#index").ids,
      "the list half of the same claim: exactly the granted record, nothing else"
  end

  test "AE2 (#65) read/write split: the same owner is denied every record-less Report key off the read list" do
    # Deliberate asymmetry, pinned so a future "fix" of it is a knowing one:
    # reads derive from the list; create and friends have no list to derive
    # from, so full_access stays barred there. Opening them off a scoped grant
    # is the #49 escalation wearing the fix's clothes (#65).
    scope_grant(@alice, role("Owner", full_access: true), @report)

    %w[reports#create reports#new reports#destroy_all].each do |key|
      assert_not @resolver.allow?(subject: @alice, permission: key, record: nil, model: Report),
        "#{key} must not open off a scoped full_access grant"
    end
  end

  test "AE4 (#65) strict agreement: a grant on a destroyed record opens nothing — ticked or full_access" do
    # The old branch matched the surviving assignment ROW and admitted the
    # subject into an empty page. Deriving from the list makes an empty list a
    # deny — fail-closed — and this is the pin that discriminates a respell
    # back to an assignment-level EXISTS, which would go green here.
    doomed = Report.create!(title: "Gone", requested_by: @bob)
    scope_grant(@alice, role("Owner", full_access: true), doomed)
    scope_grant(@bob, role("Editor", "reports#index"), doomed)
    doomed.destroy!

    assert_not @resolver.allow?(subject: @alice, permission: "reports#index", record: nil, model: Report),
      "a full_access grant on a destroyed record is an empty list — the gate must agree"
    assert_not @resolver.allow?(subject: @bob, permission: "reports#index", record: nil, model: Report),
      "an explicitly-ticked grant on a destroyed record flips too: strict means strict"
  end

  test "#65 general rule: a granted record excluded by a default_scope opens nothing, like a destroyed one" do
    # AE4's destroyed-record pin is one instance of the general rule: the read
    # arm answers from scope_for, whose model.where(id: ...) inherits the
    # model's default scope — so a granted record that is soft-deleted,
    # archived, or tenant-scoped OUT of model.all denies exactly like a
    # destroyed one, for ticked roles as much as full_access. Pinned so the
    # broader trigger (named in the CHANGELOG's Tightened callout) has its own
    # regression surface, not just the hard-destroy flavor.
    scope_grant(@alice, role("Owner", full_access: true), @report)
    scope_grant(@bob, role("Editor", "reports#index"), @report)
    original_scopes = Report.default_scopes
    Report.instance_eval { default_scope { where.not(title: "Q3") } } # @report's title — scoped out, not destroyed

    assert_not @resolver.allow?(subject: @alice, permission: "reports#index", record: nil, model: Report),
      "the list would not show a scoped-out record — the gate agrees (full_access)"
    assert_not @resolver.allow?(subject: @bob, permission: "reports#index", record: nil, model: Report),
      "and the same for an explicitly-ticked grant: strict means strict"
  ensure
    # Restore what was there (not []): wiping default_scopes would silently
    # erase a real default scope if Report ever gained one. (#89 review)
    Report.default_scopes = original_scopes
  end

  test "AE5 (#65) opt-out: an empty collection_read_actions restores the pre-#65 record-less semantics" do
    original = CurrentScope.config.collection_read_actions
    CurrentScope.config.collection_read_actions = []
    scope_grant(@alice, role("Owner", full_access: true), @report)
    scope_grant(@bob, role("Editor", "reports#index"), @report)

    assert_not @resolver.allow?(subject: @alice, permission: "reports#index", record: nil, model: Report),
      "opted out, full_access is barred from the record-less branch exactly as pre-#65"
    assert_not @resolver.allow?(subject: @alice, permission: "reports#index", record: Report)
    assert @resolver.allow?(subject: @bob, permission: "reports#index", record: nil, model: Report),
      "explicit ticks keep working through the pre-#65 ticking branch"
  ensure
    CurrentScope.config.collection_read_actions = original
  end

  test "AE6 (#65): SoD's record-less refusal beats the read list" do
    original_sod = CurrentScope.config.sod_actions
    original_reads = CurrentScope.config.collection_read_actions
    CurrentScope.config.sod_actions = %w[approve]
    CurrentScope.config.collection_read_actions = %w[index approve]
    scope_grant(@alice, role("Owner", full_access: true), @report)

    [ nil, Report ].each do |target|
      assert_not @resolver.allow?(subject: @alice, permission: "reports#approve", record: target, model: Report),
        "an SoD action is refused record-less whatever the read list says (target: #{target.inspect})"
    end
  ensure
    CurrentScope.config.sod_actions = original_sod
    CurrentScope.config.collection_read_actions = original_reads
  end

  test "#65 STI: an Invoice grant opens Document- and Invoice-declared reads via the id-narrowed query" do
    invoice = Invoice.create!(title: "INV-1")
    scope_grant(@alice, role("Owner", full_access: true), invoice)

    assert @resolver.allow?(subject: @alice, permission: "documents#index", record: nil, model: Document),
      "the grant stores resource_type Document (base_class); the Document list shows the invoice"
    assert @resolver.allow?(subject: @alice, permission: "documents#index", record: nil, model: Invoice),
      "Invoice.where(id: ...) matches — the granted row IS an Invoice"
  end

  test "#65 STI tightening: a sibling-subclass grant does not open an Invoice-declared read; create keeps the ceiling" do
    receipt = Receipt.create!(title: "RCPT-1")
    scope_grant(@alice, role("Editor", "documents#index", "documents#create"), receipt)

    # Read side: scope_for applies STI's own type predicate, so the sibling
    # collapse the old branch accepted (R6a) tightens here — fail-closed.
    assert_not @resolver.allow?(subject: @alice, permission: "documents#index", record: nil, model: Invoice),
      "the Invoice list would not show a Receipt — the gate agrees"
    # Write side: the roles_ticking branch still binds by base_class alone —
    # the accepted R6a ceiling, unchanged. The read/write split is deliberate.
    assert @resolver.allow?(subject: @alice, permission: "documents#create", record: nil, model: Invoice),
      "the non-read branch keeps its R6a base_class ceiling"
  end

  test "#65 shape-guard order: a non-AR type on a listed read still fails closed, never crashes" do
    scope_grant(@alice, role("Owner", full_access: true), @report)

    # Gadget has no base_class/where — the AR-class guard must run BEFORE the
    # scope_for branch, or this is a NoMethodError 500 instead of a clean deny.
    assert_not @resolver.allow?(subject: @alice, permission: "gadgets#index", record: Gadget)
    assert_not @resolver.allow?(subject: @alice, permission: "reports#index", record: nil, model: Gadget)

    # An ABSTRACT class passes `< ActiveRecord::Base` but has no table — the
    # read arm's scope_for would raise TableNotSpecified where the old ticking
    # arm quietly matched nothing. Deny, don't 500. (#89 review)
    assert_not @resolver.allow?(subject: @alice, permission: "reports#index", record: nil, model: ApplicationRecord)
    assert_not @resolver.allow?(subject: @alice, permission: "reports#index", record: ApplicationRecord)
  end

  test "#65 purity: the scope_for-derived branch reads only and leaves no residue between calls" do
    scope_grant(@alice, role("Owner", full_access: true), @report)

    assert_no_difference [ "CurrentScope::Event.count", "CurrentScope::ScopedRoleAssignment.count" ] do
      assert @resolver.allow?(subject: @alice, permission: "reports#index", record: nil, model: Report)
      assert_not @resolver.allow?(subject: @alice, permission: "reports#index", record: nil, model: Document),
        "a Document gate does not open off a Report grant — and leaves no residue"
      assert @resolver.allow?(subject: @alice, permission: "reports#index", record: nil, model: Report),
        "repeating the first call still allows — order-independent"
    end
  end

  # --- R6: the resolver stays a pure decision function ---

  test "R6: the new branch only reads — no rows are written" do
    scope_grant(@alice, role("Editor", "reports#index"), @report)

    assert_no_difference [ "CurrentScope::Event.count", "CurrentScope::ScopedRoleAssignment.count" ] do
      @resolver.allow?(subject: @alice, permission: "reports#index", record: nil)
      @resolver.allow?(subject: @alice, permission: "reports#index", record: Report)
      @resolver.allow?(subject: @alice, permission: "reports#destroy", record: nil)
    end
  end
end
