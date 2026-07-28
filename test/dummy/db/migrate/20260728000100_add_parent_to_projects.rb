# A self-referential parent on projects, so the dummy can express the two shapes
# #108's chain needs and nothing else in this app could reach: a chain DEEPER
# than CurrentScope::ParentChain::MAX_PARENT_DEPTH, and a multi-hop grant
# (a grant on a grandparent reaching a Report two hops down).
class AddParentToProjects < ActiveRecord::Migration[8.1]
  def change
    add_reference :projects, :parent, foreign_key: { to_table: :projects }, null: true
  end
end
