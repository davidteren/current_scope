require "test_helper"

module CurrentScope
  class ApplicationHelperTest < ActionView::TestCase
    include CurrentScope::ApplicationHelper

    setup do
      @original_label = CurrentScope.config.subject_label
      reset_subject_label_warnings
    end

    teardown do
      CurrentScope.config.subject_label = @original_label
      reset_subject_label_warnings
    end

    # The warn-once memo is module-level (helper instances are per-request), so
    # it survives between tests and would hide a later test's emission.
    def reset_subject_label_warnings
      CurrentScope::ApplicationHelper.instance_variable_set(:@subject_label_warnings, nil)
    end

    def capture_logs
      io = StringIO.new
      original = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(io)
      yield
      io.string
    ensure
      Rails.logger = original
    end

    Person = Struct.new(:email, :name)

    # --- Existing behaviour, unchanged (R4) ---

    test "a blank/whitespace email falls through to the next identifier, not an empty label" do
      CurrentScope.config.subject_label = nil # exercise the default chain
      subject = Struct.new(:email, :name).new("   ", "Fallback Person")
      assert_equal "Fallback Person", current_scope_subject_label(subject)
    end

    test "a configured label that resolves blank falls back to the default chain" do
      CurrentScope.config.subject_label = ->(_) { "" }
      subject = Struct.new(:name).new("Named Person")
      assert_equal "Named Person", current_scope_subject_label(subject)
    end

    test "a valid Proc renders its label" do
      CurrentScope.config.subject_label = ->(u) { u.email.upcase }
      assert_equal "A@B.CO", current_scope_subject_label(Person.new("a@b.co", "Ada"))
    end

    test "a valid Symbol renders that attribute" do
      CurrentScope.config.subject_label = :name
      assert_equal "Ada", current_scope_subject_label(Person.new("a@b.co", "Ada"))
    end

    test "a nil subject is (none)" do
      CurrentScope.config.subject_label = ->(u) { u.email.upcase }
      assert_equal "(none)", current_scope_subject_label(nil)
    end

    # --- R1: a raising Proc must not take the page down ---

    # The issue's exact repro: a Proc that is fine for most subjects and trips
    # on one with incomplete data.
    test "a Proc that raises for one subject falls back instead of raising" do
      CurrentScope.config.subject_label = ->(u) { u.email.upcase } # NoMethodError on nil
      subject = Person.new(nil, "Ada")

      assert_nothing_raised do
        assert_equal "Ada", current_scope_subject_label(subject)
      end
    end

    # Per-subject isolation, not a per-page catch: one bad row must not degrade
    # the labels of the good rows around it.
    test "a raising Proc isolates the bad subject and leaves the rest labelled" do
      CurrentScope.config.subject_label = ->(u) { u.email.upcase }
      good = Person.new("a@b.co", "Good")
      bad  = Person.new(nil, "Bad Person")

      assert_equal "A@B.CO", current_scope_subject_label(good)
      assert_equal "Bad Person", current_scope_subject_label(bad)
      assert_equal "A@B.CO", current_scope_subject_label(good), "the good rows keep working after a bad one"
    end

    # KTD-2: a host Proc is arbitrary code and can raise anything, so scoping the
    # rescue to the NameError family would leave R1 half-met — the same bug
    # returns for a differently-broken Proc.
    test "any StandardError from a Proc falls back, not just NoMethodError" do
      [ ArgumentError, KeyError, RuntimeError, Class.new(StandardError) ].each do |klass|
        reset_subject_label_warnings
        CurrentScope.config.subject_label = ->(_) { raise klass, "boom" }

        # "a@b.co", not "Ada": the fallback is the default chain, which prefers
        # email over name.
        assert_equal "a@b.co", current_scope_subject_label(Person.new("a@b.co", "Ada")),
          "#{klass} must not escape the label helper"
      end
    end

    test "a Symbol naming a method that raises falls back too" do
      klass = Struct.new(:name) do
        def bad_label = raise("boom")
      end
      CurrentScope.config.subject_label = :bad_label

      assert_equal "Ada", current_scope_subject_label(klass.new("Ada"))
    end

    # --- R3: a typo'd Symbol must not be silent ---

    test "a Symbol the subject cannot answer warns once, naming the symbol" do
      CurrentScope.config.subject_label = :emial

      logs = capture_logs do
        assert_equal "a@b.co", current_scope_subject_label(Person.new("a@b.co", "Ada"))
        assert_equal "c@d.co", current_scope_subject_label(Person.new("c@d.co", "Grace"))
      end

      assert_equal 1, logs.scan(/config\.subject_label/).size, "one line per mistake, not one per subject"
      assert_match ":emial", logs
    end

    test "a valid Symbol never warns" do
      CurrentScope.config.subject_label = :name

      logs = capture_logs { current_scope_subject_label(Person.new("a@b.co", "Ada")) }

      assert_empty logs
    end

    # --- A raising Proc is also a mistake, and also deserves a signal ---
    #
    # Beyond the plan, but its own KTD-3 reasoning applies: a Symbol naming a
    # nonexistent method warrants a nudge because it is unambiguously a mistake.
    # A Proc that raises is no less so, and rescuing it silently would swallow an
    # exception without a trace — the same silence this issue exists to remove.

    test "a raising Proc warns once, naming the error" do
      CurrentScope.config.subject_label = ->(u) { u.email.upcase }

      logs = capture_logs do
        current_scope_subject_label(Person.new(nil, "Ada"))
        current_scope_subject_label(Person.new(nil, "Grace"))
      end

      assert_equal 1, logs.scan(/config\.subject_label/).size, "one line per mistake, not one per subject"
      assert_match "NoMethodError", logs
    end

    test "a Proc that resolves blank is not an error and never warns" do
      # Blank is a documented, legitimate fall-through (pinned above) — only a
      # RAISE is a mistake.
      CurrentScope.config.subject_label = ->(_) { "" }

      logs = capture_logs { current_scope_subject_label(Person.new("a@b.co", "Ada")) }

      assert_empty logs
    end

    test "a working Proc never warns" do
      CurrentScope.config.subject_label = ->(u) { u.email.upcase }

      logs = capture_logs { current_scope_subject_label(Person.new("a@b.co", "Ada")) }

      assert_empty logs
    end

    # --- A label that is neither callable nor a method name ---
    #
    # respond_to? raises TypeError ("false is not a symbol nor a string") on
    # anything that isn't a Symbol/String, and that raise lands OUTSIDE the
    # rescue guarding the send — so a mistyped config still 500'd the page. The
    # bug this helper exists to prevent, through a different door.

    test "a label that is neither callable nor a method name falls back, never raises" do
      [ false, 0, Object.new, [], {}, 3.14 ].each do |unusable|
        reset_subject_label_warnings
        CurrentScope.config.subject_label = unusable

        # respond_to?(0) raises TypeError — must never reach the page.
        assert_nothing_raised do
          assert_equal "a@b.co", current_scope_subject_label(Person.new("a@b.co", "Ada")),
            "subject_label = #{unusable.class} must fall back, not 500"
        end
      end
    end

    test "an unusable label warns once, naming the type rather than the value" do
      CurrentScope.config.subject_label = 0

      logs = capture_logs do
        current_scope_subject_label(Person.new("a@b.co", "Ada"))
        current_scope_subject_label(Person.new("c@d.co", "Grace"))
      end

      assert_equal 1, logs.scan(/config\.subject_label/).size
      assert_match "Integer", logs
    end

    # The warning runs on the path that exists to stop a raise, so it must not
    # raise either. Naming the label's TYPE rather than inspecting its value is
    # what makes that true for an arbitrary host object.
    test "an unusable label whose inspect raises still falls back" do
      hostile = Class.new do
        def inspect = raise("inspect exploded")
      end.new
      CurrentScope.config.subject_label = hostile

      assert_nothing_raised do
        assert_equal "a@b.co", current_scope_subject_label(Person.new("a@b.co", "Ada"))
      end
    end

    # --- The warning is one log record, whatever the host's exception says ---

    test "a multi-line exception message is flattened into one log line" do
      CurrentScope.config.subject_label = ->(_) { raise "line one\nline two\rline three" }

      logs = capture_logs { current_scope_subject_label(Person.new("a@b.co", "Ada")) }

      assert_equal 1, logs.lines.size, "an exception message must not split the warning across records"
      assert_match "line one line two line three", logs
    end

    # --- Reporting the failure must not become the failure ---
    #
    # Everything in the warning path runs inside the rescue that stops the 500,
    # so an exception whose own #message raises would escape it — turning the
    # diagnostic into the outage it was diagnosing.

    test "an exception whose message raises still falls back and still warns" do
      hostile = Class.new(StandardError) do
        def message = raise("message exploded")
      end
      CurrentScope.config.subject_label = ->(_) { raise hostile }

      logs = capture_logs do
        assert_nothing_raised do
          assert_equal "a@b.co", current_scope_subject_label(Person.new("a@b.co", "Ada"))
        end
      end

      assert_match "config.subject_label", logs, "a broken message must not cost us the warning"
      assert_match "(message unavailable)", logs
    end

    # --- A label that can't even be classified ---
    #
    # Every branch calls a method ON the config value to classify it (nil?,
    # respond_to?, is_a?). A value that breaks those breaks the classification
    # before any guard can guard it, so the last-resort rescue is the only
    # place this can be caught.

    test "an exception overriding #class keeps its own warning, not a misattributed one" do
      # #class is interpolated before safe_message can run. The method-level
      # rescue already stops this reaching the page — but without safe_class the
      # accurate warning is lost and replaced by one about the SECOND failure,
      # which points at the wrong thing.
      hostile = Class.new(StandardError) do
        def class = raise("class exploded")
      end
      CurrentScope.config.subject_label = ->(_) { raise hostile }

      logs = capture_logs do
        assert_nothing_raised do
          assert_equal "a@b.co", current_scope_subject_label(Person.new("a@b.co", "Ada"))
        end
      end

      assert_match "config.subject_label raised", logs, "the accurate warning must survive"
      assert_no_match(/could not be read/, logs, "and must not degrade to the fallback warning")
    end

    test "a label that cannot be classified falls back instead of 500ing" do
      CurrentScope.config.subject_label = BasicObject.new # no #nil?, no #class

      assert_nothing_raised do
        assert_equal "a@b.co", current_scope_subject_label(Person.new("a@b.co", "Ada"))
      end
    end

    test "an unclassifiable label warns once, without touching the label" do
      CurrentScope.config.subject_label = BasicObject.new

      logs = capture_logs do
        current_scope_subject_label(Person.new("a@b.co", "Ada"))
        current_scope_subject_label(Person.new("c@d.co", "Grace"))
      end

      assert_equal 1, logs.scan(/config\.subject_label/).size
      assert_match "could not be read", logs
    end

    # --- GID labels: the ledger outlives the identities it names ---
    #
    # GlobalID::Locator.locate RAISES RecordNotFound for a deleted record and
    # NameError for a renamed class — nil is only for unparseable strings. The
    # events page must degrade to the raw GID, not 500.

    test "a GID whose record was deleted falls back to the raw GID string" do
      user = User.create!(name: "Ephemeral")
      gid = user.to_gid.to_s
      user.destroy!

      assert_equal gid, current_scope_gid_label(gid)
    end

    test "a GID naming a class that no longer exists falls back to the raw GID string" do
      gid = User.create!(name: "Anchor").to_gid.to_s.sub("User", "NoSuchClass")

      assert_equal gid, current_scope_gid_label(gid)
    end

    test "a GID for a live record still renders its label" do
      user = User.create!(name: "Alive")

      assert_equal "Alive", current_scope_gid_label(user.to_gid.to_s)
    end
  end
end
