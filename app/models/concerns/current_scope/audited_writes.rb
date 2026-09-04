# frozen_string_literal: true

module CurrentScope
  # Every write path leaves a trail, not just the console one (#182).
  #
  # The console recorded its own events, so a grant re-derived by the seed task
  # through `find_or_create_by!` left nothing behind. That turns a recovery into
  # an audit lie: after a role delete cascaded 187 revocations into the ledger,
  # restoring all 187 added no rows, and anyone auditing later reads the
  # revocations, finds no restoration, and concludes access is still gone when it
  # is fully restored. The same asymmetry ran the other way for a model-level
  # destroy.
  #
  # The events are emitted from model callbacks instead, so the console, a seed,
  # a rake task and a console one-liner all record the same thing.
  module AuditedWrites
    extend ActiveSupport::Concern

    private

    # IN the transaction, not after_commit. `config.audit = :strict` is
    # documented to roll a mutation back when its audit row cannot be written,
    # and an after_commit callback fires too late to do that. It also means a
    # rolled-back write takes its event with it, which is the behaviour the
    # console already had.
    #
    # Attribution follows CurrentScope.grant!'s bootstrap events rather than
    # inventing a second convention: Event.record! needs an actor it can name
    # with a GlobalID, and a seed has no human behind it, so the write is
    # self-attributed to the record it is about.
    #
    # `attribution`, NOT `source`: this ledger already uses `details["source"]`
    # for two other things — the file path a definitions document came from, and
    # "bootstrap" on CurrentScope.grant!'s rows — so a third meaning on nine more
    # event types would leave an auditor unable to filter on any of them (#182
    # review).
    #
    # It says which of the two attributions this row took, and NOTHING MORE.
    # "actor" means
    # an ambient IDENTITY existed — Current.actor answers `super || user`, so a
    # request, a job, with_current_user in a test, or simply an ambient user all
    # produce it — and "self" means none did. Calling it "request" would be a
    # claim this code cannot make, and an auditor filtering on it would get a
    # wrong set (#182 review).
    def audit_write!(event, target:, details: {})
      # Event.record! returns nil when auditing is off, but the CALLER has
      # already resolved the subject and the resource label to get here — two
      # queries per grant, on a host that asked for none. The seed that motivated
      # this issue restores 187 grants (#182 review).
      return unless CurrentScope.config.audit

      actor = CurrentScope::Current.actor

      CurrentScope::Event.record!(
        event: event,
        target: target,
        details: details.merge(attribution: actor ? "actor" : "self"),
        actor: actor || target
      )
    end
  end
end
