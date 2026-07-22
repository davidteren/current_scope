module CurrentScope
  # Inherits from the host's controller (config.parent_controller) so the
  # host's authentication — and its Context before_action — run first.
  # The management UI is the place permissions are granted, so it cannot be
  # gated by grantable permissions: only full_access subjects get in.
  class ApplicationController < CurrentScope.config.parent_controller.constantize
    # The read-only-while-impersonating gate, installed directly (not via Guard):
    # this controller SKIPS the permission check, and mutations here — role,
    # grant, and grid edits — are the highest-value surface to keep read-only
    # while impersonating. Host stop-impersonation/sign-out/sign-in endpoints
    # skip it with skip_before_action :current_scope_mutation_guard!.
    include CurrentScope::MutationGuard

    layout "current_scope/application"

    # The engine's controllers are excluded from the grantable catalog; they
    # answer to require_full_access! instead of the host's Guard gate.
    skip_before_action :current_scope_check!, raise: false

    before_action :require_full_access!

    private

    # Raises rather than rendering, so the engine's front door lands in the same
    # current_scope_denied path as every other denial and gets the reason header
    # for free. It used to `head :forbidden` here — the one denial in the gem
    # that sat outside that machinery, and so the one with no reason and no body
    # (#23). MutationGuard's rescue_from catches this from a before_action.
    #
    # Who is denied is unchanged: the full_access? check is byte-for-byte what
    # it was. Only how the refusal is surfaced changed.
    def require_full_access!
      return if CurrentScope.resolver.full_access?(CurrentScope::Current.user)

      key = "#{controller_path}##{action_name}"
      raise CurrentScope::AccessDenied.new(
        key,
        reason: :not_full_access,
        permission: key,
        subject: CurrentScope::Current.user
      )
    end

    # The engine's UI is the one place a rendered denial belongs: the admin is
    # looking at a browser, and "blank page" is not an answer to "why can't I get
    # in?". Overrides ONLY the body — the reason header is still written by
    # current_scope_denied, which stays the single place that knows about it.
    #
    # ONLY for :not_full_access. This concern rescues EVERY AccessDenied raised
    # in this controller, and the other one that fires here is the impersonation
    # gate — whose subject usually DOES have full access and is refused for an
    # entirely different reason. Telling them they need a full-access role is a
    # confidently wrong answer, which is worse than the blank page this fix
    # replaces. Every other reason falls through to the bodyless default, i.e.
    # exactly what it did before this change.
    #
    # HTML only: the page is a full HTML document, so a client that asked for
    # anything else gets the bodyless 403 rather than markup under a content
    # type it did not ask for.
    #
    # layout: false — the console layout is a sidebar of links to areas this
    # subject cannot open. Offering them reads as "you're in" and then refuses
    # every click.
    def current_scope_render_denied(reason = nil)
      return super unless reason == :not_full_access && request.format.html?

      render "current_scope/shared/access_denied", status: :forbidden, layout: false
    end

    def subject_class
      @subject_class ||= CurrentScope.config.subject_class.constantize
    end

    # The submitted subject GIDs for a bulk-or-single action: the multi-select
    # subject_gids[] when present, else the single subject_gid. Raw strings —
    # pass through locate_subjects to resolve and enforce the subject boundary.
    def submitted_subject_gids
      gids = Array(params[:subject_gids]).select(&:present?)
      gids = [ params[:subject_gid] ].compact if gids.empty?
      gids
    end

    # Resolve subject GIDs to records, keeping ONLY instances of the configured
    # subject_class. A crafted subject_gids[] pointing at some other model must
    # never create an assignment row for a non-subject — the picker offers only
    # subjects, so anything else is out of bounds. Dead/unknown GIDs drop out.
    def locate_subjects(gids)
      Array(gids).select(&:present?).filter_map do |gid|
        record = GlobalID::Locator.locate(gid)
        record if record.is_a?(subject_class)
      rescue ActiveRecord::RecordNotFound, NameError
        nil
      end.uniq # duplicate subject_gids[] must count once (notice + audit accuracy)
    end
  end
end
