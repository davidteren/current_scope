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

    def require_full_access!
      head :forbidden unless CurrentScope.resolver.full_access?(CurrentScope::Current.user)
    end

    def subject_class
      @subject_class ||= CurrentScope.config.subject_class.constantize
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
      end
    end
  end
end
