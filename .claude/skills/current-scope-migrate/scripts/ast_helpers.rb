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
           Prism::FloatNode, Prism::RationalNode, Prism::ImaginaryNode,
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
    # UNPROVABLE (nil) if ANY link carries arguments or a block:
    # `user.lookup(params[:id])` must never root as a plain user chain —
    # its result depends on more than the user.
    def receiver_root(node)
      current = node
      while current.is_a?(Prism::CallNode)
        return nil if current.arguments || current.block
        break if current.receiver.nil?

        current = current.receiver
      end
      case current
      when Prism::CallNode, Prism::LocalVariableReadNode then current.name
      end
    end

    # A receiverless, argument-less, block-less call — nothing else counts
    # as "bare" (a call with args/blocks is a computation, not a reference).
    def bare_call?(node, name)
      node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == name &&
        node.arguments.nil? && node.block.nil?
    end
  end
end
