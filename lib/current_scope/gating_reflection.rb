module CurrentScope
  # Answers one question about a controller path: is it PROVEN that
  # current_scope_check! never runs there? True only when the callback is
  # ABSENT from the class's callback chain — the one thing the chain states
  # unconditionally. Everything else is false:
  #
  #   - callback present and unconditional → gated → false
  #   - callback present wearing a condition (skip_before_action only:) →
  #     UNPROVABLE without evaluating ActionFilter internals, which this class
  #     must never do (KTD-3) → false. The naive any?/none? presence check
  #     inverts exactly here — see the ProblemFrame characterization in
  #     test/gating_reflection_test.rb — and per-action guessing is how a
  #     fail-open gets reported as gated.
  #   - no controller class routed at that path → nothing to prove → false
  #
  # Absence is an EFFECT, not a cause: a bare skip_before_action, an inherited
  # bare skip (#62), and never including Guard at all are the same verdict,
  # because the chain looks the same. That is deliberate — the question is
  # "does the gate run?", not "why not?".
  #
  # Named beside GatingTripwire: both interrogate the same subject (is this
  # action gated?), the tripwire at request time, this one by reflection.
  class GatingReflection
    def ungated?(controller_path)
      klass = controller_class_for(controller_path)
      # A controller without the callbacks API at all (a bare ActionController::
      # Metal without AbstractController::Callbacks) cannot run a before_action
      # — the gate PROVABLY never runs there. Without this check the reflection
      # would raise NoMethodError instead of answering. (#79 review)
      return true unless klass.respond_to?(:_process_action_callbacks)

      klass
        ._process_action_callbacks
        .none? { |callback| callback.kind == :before && callback.filter == :current_scope_check! }
    rescue ActionDispatch::MissingController
      # A routed path with no controller class (a scaffolding leftover, a
      # not-yet-written controller) proves nothing about gating. Silent false,
      # matching the prove-or-stay-silent discipline of
      # warn_on_cross_controller_derivation. Surface that shape via
      # #missing_controller? instead — the grid badges it (#43).
      false
    end

    # True when the path is routed but no controller class loads (stale route /
    # typo). Distinct from ungated?: there is nothing to gate. Hitting the
    # route is ActionDispatch::MissingController (a 500 in production), so the
    # role grid flags the row (#43). Uses the same Rails path→class rule as
    # #ungated? so the two answers cannot disagree on loadability.
    def missing_controller?(controller_path)
      controller_class_for(controller_path)
      false
    rescue ActionDispatch::MissingController
      true
    end

    private

    # Rails owns the path→class rule — camelize, namespacing, the Controller
    # suffix, and crucially the NameError triage: a missing CONTROLLER constant
    # becomes MissingController (rescued above), while a NameError raised from
    # inside the controller's own broken body re-raises as-is and must
    # PROPAGATE out of ungated? (a blanket rescue NameError would silently
    # report a broken controller as gated). Hand-rolling camelize+constantize
    # would have to reimplement that triage and would drift. (KTD-2)
    #
    # controller_class_for lives on Request, so a throwaway request object is
    # the price of asking. Built lazily and memoized here, NEVER in initialize:
    # the role-save path constructs a GatingReflection it may never ask — any
    # failure in construction would 500 role saves. (KTD-8)
    # Memoize path→class for the life of this reflection instance. The role
    # editor asks ungated? and missing_controller? per row; without a cache
    # that is two constantizes per controller (cubic P2 on #43).
    def controller_class_for(controller_path)
      @class_for ||= {}
      return @class_for[controller_path] if @class_for.key?(controller_path)

      @request ||= ActionDispatch::Request.new({})
      @class_for[controller_path] = @request.controller_class_for(controller_path)
    end
  end
end
