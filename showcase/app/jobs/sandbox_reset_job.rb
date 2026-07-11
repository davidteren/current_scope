# Self-heals the public sandbox: reverts vandalism (a visitor acting as Owner
# deleting roles, approving records, renaming props) back to the seeded ground
# truth. Runs on a 15-minute schedule (config/recurring.yml) and on demand
# (SandboxController#reset).
#
# NEVER db:reset — the SQLite files are held open by the running process. Instead
# one transaction rewrites the data in place. Order is dictated by the engine's
# RESTRICT foreign keys (deleting a role with any assignment/permission still
# attached raises InvalidForeignKey), so every grant is cleared BEFORE any role.
class SandboxResetJob < ApplicationJob
  # ponytail: 3h keeps in-flight visitors' sessions alive while capping growth on
  # the volume-backed SQLite file (crawlers mint one Visitor session per hit).
  # Widen if a demo walkthrough ever runs longer than 3h.
  SESSION_TTL = 3.hours

  def perform
    # ponytail: one transaction, and NO bcrypt inside it — seeded users are
    # found (never recreated), so the txn stays well under SQLite's ~5s busy
    # timeout even while a request holds the write lock.
    ActiveRecord::Base.transaction do
      # 1. Clear ALL authorization grants first, in FK-safe order. This is what
      #    makes the killer case safe: a visitor-created role that was assigned
      #    to a user has its assignment removed here, BEFORE the role in step 3.
      CurrentScope::ScopedRoleAssignment.delete_all
      CurrentScope::RoleAssignment.delete_all
      CurrentScope::RolePermission.delete_all

      # 2. Restore canonical state: recreates deleted seed records, reverts
      #    mutated ones, and rebuilds every seed grant against current records.
      seeded = Showcase::Seeds.plant!

      # 3. Delete everything a visitor added (roles now carry no grants → FK-safe)
      #    and every visitor-created / renamed-away domain record.
      CurrentScope::Role.where.not(id: seeded[:role_ids]).delete_all
      PayRun.where.not(id: seeded[:pay_runs]).delete_all
      Contract.where.not(id: seeded[:contracts]).delete_all
      ExpenseClaim.where.not(id: seeded[:expense_claims]).delete_all

      # 4. Clear the append-only ledger LAST. delete_all is the sanctioned bypass
      #    of Event#readonly? (SQLite has no TRUNCATE) — see the Event header.
      CurrentScope::Event.delete_all

      # 5. Prune stale sessions (crawlers mint one Visitor session per hit, so
      #    these are overwhelmingly Visitor rows). Recent ones survive so
      #    in-flight visitors keep browsing — a now-stale act-as id, if that
      #    persona was reset, is handled loudly by U11's clear_stale_acting_as.
      prune_stale_sessions
    end
  end

  private

  def prune_stale_sessions
    Session.where(created_at: ...SESSION_TTL.ago).delete_all
  end
end
