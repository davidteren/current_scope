class Report < ApplicationRecord
  belongs_to :project, optional: true
  belongs_to :requested_by, class_name: "User"

  # SoD hook: whoever requested the report can never approve it.
  def current_scope_initiator
    requested_by
  end

  # Break-glass opt-in. A real host reads a per-record flag column (gated on the
  # bypass permission); the dummy exposes a class-level toggle for tests.
  class_attribute :sod_bypass_glass, default: false, instance_writer: false
  def current_scope_sod_bypassed? = self.class.sod_bypass_glass
end
