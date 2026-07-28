class Report < ApplicationRecord
  belongs_to :project, optional: true
  belongs_to :requested_by, class_name: "User"

  # #108: a scoped grant held on the Project reaches its Reports. The SoD hook
  # below still names the REPORT's requester — the chain feeds grant matching
  # only, never the veto.
  current_scope_parent :project

  # SoD hook: whoever requested the report can never approve it.
  def current_scope_initiator
    requested_by
  end

  # Break-glass opt-in. A real host reads a per-record flag column (gated on the
  # bypass permission); the dummy exposes a class-level toggle for tests.
  class_attribute :sod_bypass_glass, default: false, instance_writer: false
  def current_scope_sod_bypassed? = self.class.sod_bypass_glass
end
