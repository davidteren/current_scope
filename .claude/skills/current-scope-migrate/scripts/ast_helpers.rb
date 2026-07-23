# frozen_string_literal: true

# Leaf AST predicates shared by the three migrate-skill scripts
# (policy_inventory, ability_inventory, callsite_rewrite). Only helpers with
# ONE correct answer live here — user_only?/user_chain? stay per-script
# because Pundit's `user` is a method call while CanCanCan's is a local
# variable, and unifying them would blur that proof.
module CurrentScopeMigrate
  module AstHelpers
    # Literals, including arrays of literals (%w[admin editor]).
    def literal?(node)
      case node
      when Prism::StringNode, Prism::SymbolNode, Prism::IntegerNode,
           Prism::TrueNode, Prism::FalseNode, Prism::NilNode
        true
      when Prism::ArrayNode
        node.elements.all? { |e| literal?(e) }
      else
        false
      end
    end

    # The name at the root of a receiver chain — a no-arg call (`user` the
    # attr_reader) or a local variable (`user` the parameter) alike.
    def receiver_root(node)
      current = node
      current = current.receiver while current.is_a?(Prism::CallNode) && current.receiver
      case current
      when Prism::CallNode, Prism::LocalVariableReadNode then current.name
      end
    end

    def bare_call?(node, name)
      node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == name
    end
  end
end
