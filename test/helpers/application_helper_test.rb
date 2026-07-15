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
  end
end
