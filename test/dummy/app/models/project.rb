# #108: a Project may itself sit under a parent Project, so the dummy can
# express a MULTI-HOP chain (a grant on a grandparent reaching a Report two hops
# down) and a chain deeper than CurrentScope::ParentChain::MAX_PARENT_DEPTH.
#
# Deliberately NO current_scope_initiator — a Project is not SoD-gated, and
# defining one here is the exact trap the resolver's ConfigurationError warns
# about: it would make the veto measure the project's initiator instead of the
# report's requester, silently.
class Project < ApplicationRecord
  belongs_to :parent, class_name: "Project", optional: true
  has_many :children, class_name: "Project", foreign_key: :parent_id, dependent: :nullify
  # :nullify, so destroying a parent ORPHANS its reports rather than deleting
  # them — that is the shape the destroyed-parent pin needs (a grant on a gone
  # parent must open nothing, the one-hop-up analogue of AE4).
  has_many :reports, dependent: :nullify

  current_scope_parent :parent
end
