# frozen_string_literal: true

# Deterministic CanCanCan ability inventory (#45 phase 3).
#
#   ruby ability_inventory.rb app/models/ability.rb   # JSON to stdout
#   ruby ability_inventory.rb --self-test
#
# Honest contract (same as policy_inventory.rb): classify only what the AST
# PROVES. A `can` call is provable when its enclosing guards are user-only
# and its condition hash (if any) compares record columns to the user:
#   pure_role   — no condition hash, user-only guards: role + grid ticks
#                 (`can :manage, :all` under a user-only guard = full_access)
#   ownership   — hash condition binding a record column to the user
#   unparseable — blocks, `cannot`, record-attribute conditions, non-user
#                 guards, splats — reported verbatim for a human
require "json"
require "set"

begin
  require "prism"
rescue LoadError
  abort "prism is required (bundled with Ruby >= 3.3; on 3.2 add `gem \"prism\"`)."
end

module CurrentScopeMigrate
  class AbilityInventory
    Result = Struct.new(:file, :method, :line, :bucket, :source, :actions, :subjects,
                        :guards, :detail, keyword_init: true) do
      def to_h = super.compact
    end

    def initialize(path)
      @path = path
    end

    def run
      parse = Prism.parse_file(@path)
      unless parse.success?
        err = parse.errors.first
        return { rules: [ Result.new(file: @path, method: nil,
                                     line: err&.location&.start_line || 1,
                                     bucket: "unparseable", source: nil,
                                     detail: "syntax error: #{err&.message}").to_h ] }
      end

      @source = parse.source.source
      rules = []
      each_ability_method(parse.value) do |def_node|
        walk_method(def_node.body, def_node.name.to_s, [], rules)
      end
      { rules: rules.map(&:to_h) }
    end

    private

    # Every instance method of a class named *Ability (or including
    # CanCan::Ability) can define rules — initialize commonly delegates to
    # role-named helper methods.
    def each_ability_method(node, inside_ability = false, &blk)
      if node.is_a?(Prism::ClassNode)
        name = node.constant_path.respond_to?(:full_name) ? node.constant_path.full_name : node.constant_path.slice.to_s
        inside_ability = name.end_with?("Ability") || includes_cancan?(node)
      end
      yield node if inside_ability && node.is_a?(Prism::DefNode)
      return unless node.respond_to?(:child_nodes)

      node.child_nodes.compact.each { |c| each_ability_method(c, inside_ability, &blk) }
    end

    def includes_cancan?(class_node)
      return false unless class_node.body.respond_to?(:body)

      class_node.body.body.any? do |child|
        child.is_a?(Prism::CallNode) && child.name == :include &&
          (child.arguments&.arguments || []).any? { |a| slice(a).include?("CanCan::Ability") }
      end
    end

    # Depth-first with the enclosing conditional chain carried along. Only
    # if/unless conditions are tracked; any other container (case, rescue,
    # loops) makes rules inside it unprovable.
    def walk_method(node, method_name, guards, rules)
      case node
      when nil then nil
      when Prism::StatementsNode
        # Sequential: a guard-clause return (`return unless user.admin?`)
        # guards every FOLLOWING statement. `unless` + return means the rest
        # runs when the predicate is TRUE (provable as-is); `if` + return
        # means the rest runs on the NEGATION (not provable as a role —
        # fail closed).
        implicit = []
        node.body.each do |stmt|
          walk_method(stmt, method_name, guards + implicit, rules)
          implicit += implicit_guards_from(stmt)
        end
      when Prism::IfNode, Prism::UnlessNode
        guard = { source: slice(node.predicate), user_only: user_only?(node.predicate),
                  negated: node.is_a?(Prism::UnlessNode) }
        walk_method(node.statements, method_name, guards + [ guard ], rules)
        # The else/elsif arm's guard is the NEGATION — not provable as a
        # simple role predicate, so mark it un-user-only (fail closed).
        if (arm = else_arm(node))
          negated = { source: "!(#{slice(node.predicate)})", user_only: false, negated: true }
          walk_method(arm, method_name, guards + [ negated ], rules)
        end
      when Prism::CallNode
        if node.receiver.nil? && %i[can cannot].include?(node.name)
          rules << classify_rule(node, method_name, guards)
        end
        node.child_nodes.compact.each { |c| walk_method(c, method_name, guards, rules) }
      when Prism::CaseNode, Prism::CaseMatchNode, Prism::WhileNode, Prism::UntilNode,
           Prism::RescueNode, Prism::BeginNode
        # Containers whose conditions we do not model: everything inside is
        # guarded by something unprovable.
        poison = { source: "(#{node.class.name.split('::').last} container)", user_only: false, negated: false }
        node.child_nodes.compact.each { |c| walk_method(c, method_name, guards + [ poison ], rules) }
      else
        node.child_nodes.compact.each { |c| walk_method(c, method_name, guards, rules) } if node.respond_to?(:child_nodes)
      end
    end

    TERMINATORS = [ Prism::ReturnNode, Prism::NextNode, Prism::BreakNode ].freeze

    # IfNode chains via #subsequent; UnlessNode's else arm is #else_clause.
    def else_arm(node)
      if node.respond_to?(:subsequent) then node.subsequent
      elsif node.respond_to?(:else_clause) then node.else_clause
      end
    end

    def implicit_guards_from(stmt)
      return [] unless (stmt.is_a?(Prism::IfNode) || stmt.is_a?(Prism::UnlessNode)) &&
                       else_arm(stmt).nil?

      body = stmt.statements&.body || []
      terminates = body.any? && body.all? do |s|
        TERMINATORS.any? { |t| s.is_a?(t) } ||
          (s.is_a?(Prism::CallNode) && s.receiver.nil? && s.name == :raise)
      end
      return [] unless terminates

      if stmt.is_a?(Prism::UnlessNode)
        [ { source: slice(stmt.predicate), user_only: user_only?(stmt.predicate), negated: false } ]
      else
        [ { source: "!(#{slice(stmt.predicate)})", user_only: false, negated: true } ]
      end
    end

    def classify_rule(node, method_name, guards)
      base = { file: @path, method: method_name, line: node.location.start_line,
               source: slice(node), guards: guards.map { |g| g[:source] } }
      args = node.arguments&.arguments || []
      actions = symbol_list(args[0])
      subjects = subject_list(args[1])

      bucket, detail =
        if node.name == :cannot
          [ "unparseable", "subtractive rule — express as roles that simply do not tick " \
                          "these keys, then prove it with the parity harness" ]
        elsif node.block
          [ "unparseable", "block condition — arbitrary Ruby; decide by hand" ]
        elsif guards.any? { |g| !g[:user_only] }
          [ "unparseable", "guarded by a condition that is not provably user-only " \
                          "(#{guards.reject { |g| g[:user_only] }.map { |g| g[:source] }.join('; ')})" ]
        elsif actions.nil? || subjects.nil?
          [ "unparseable", "actions/subjects not literal symbols or constants" ]
        elsif args.size <= 2
          if actions == [ "manage" ] && subjects == [ "all" ]
            [ "pure_role", "can :manage, :all — full_access role shape (guards name the role)" ]
          else
            [ "pure_role", "unconditional grant — role ticks these keys (guards name the role)" ]
          end
        elsif args.size == 3 && hash_condition(args[2])
          hash_condition(args[2])
        else
          [ "unparseable", "extra arguments not provable" ]
        end

      Result.new(**base, bucket: bucket, actions: actions, subjects: subjects, detail: detail)
    end

    # nil (unprovable) | [names]
    def symbol_list(node)
      case node
      when Prism::SymbolNode then [ node.unescaped ]
      when Prism::ArrayNode
        names = node.elements.map { |e| e.is_a?(Prism::SymbolNode) ? e.unescaped : nil }
        names.all? ? names : nil
      end
    end

    def subject_list(node)
      case node
      when Prism::SymbolNode then [ node.unescaped ]
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        [ node.respond_to?(:full_name) ? node.full_name : slice(node) ]
      when Prism::ArrayNode
        names = node.elements.map { |e| subject_list(e)&.first }
        names.all? ? names : nil
      end
    end

    # [bucket, detail] for a condition hash, or nil when not a plain hash.
    def hash_condition(node)
      return nil unless node.is_a?(Prism::HashNode) || node.is_a?(Prism::KeywordHashNode)

      kinds = node.elements.map do |el|
        next :unprovable unless el.is_a?(Prism::AssocNode)

        if user_chain?(el.value)
          :ownership
        elsif literal?(el.value)
          :attribute
        else
          :unprovable
        end
      end
      if kinds.uniq == [ :ownership ]
        [ "ownership", "record-column-vs-user condition — maps to a scoped role " \
                       "(backfill + grant-on-create hook, review required)" ]
      elsif kinds.include?(:unprovable)
        [ "unparseable", "condition hash value not provable" ]
      else
        [ "unparseable", "record-attribute condition (ABAC) — keep as a plain guard " \
                        "or restructure; current_scope is deliberately not ABAC" ]
      end
    end

    # Shared shape with policy_inventory.rb: user-only call chains, literal
    # args, no blocks, no ordering comparisons, no literal-rooted chains.
    ORDERING_OPS = %i[< > <= >= <=> =~ !~].freeze

    def user_only?(node)
      case node
      when Prism::AndNode, Prism::OrNode
        user_only?(node.left) && user_only?(node.right)
      when Prism::CallNode
        return false if ORDERING_OPS.include?(node.name)
        return false if node.name == :record || receiver_root(node) == :record
        return false if node.block
        if node.name == :! && node.receiver
          return user_only?(node.receiver)
        end
        if %i[== !=].include?(node.name)
          args = node.arguments&.arguments || []
          return args.size == 1 && user_only?(node.receiver) && (literal?(args.first) || user_only?(args.first))
        end
        return false unless (node.arguments&.arguments || []).all? { |a| literal?(a) || user_only?(a) }

        case node.receiver
        when nil then node.name == :user
        when Prism::CallNode, Prism::LocalVariableReadNode then user_only?(node.receiver)
        else false
        end
      when Prism::LocalVariableReadNode
        # In an Ability, `user` is the initialize/helper PARAMETER — a local
        # variable, unlike Pundit's attr_reader call.
        node.name == :user
      else
        literal?(node)
      end
    end

    def user_chain?(node)
      return true if node.is_a?(Prism::LocalVariableReadNode) && node.name == :user

      node.is_a?(Prism::CallNode) &&
        (receiver_root(node) == :user || (node.receiver.nil? && node.name == :user))
    end

    # Walks to the chain's root; names it for CallNode and local-variable
    # roots alike (`user.posts.count` and `user` the parameter both root at
    # :user).
    def receiver_root(node)
      current = node
      current = current.receiver while current.is_a?(Prism::CallNode) && current.receiver
      case current
      when Prism::CallNode then current.name
      when Prism::LocalVariableReadNode then current.name
      end
    end

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

    def slice(node)
      @source.byteslice(node.location.start_offset...node.location.end_offset)
    end
  end
end

# --- self-test --------------------------------------------------------------

if ARGV.first == "--self-test"
  require "tmpdir"
  FIXTURE = <<~RUBY
    class Ability
      include CanCan::Ability

      def initialize(user)
        user ||= User.new
        if user.admin?
          can :manage, :all
        end
        can :read, Post if user.role == "editor"
        can :update, Post, author_id: user.id
        can :read, Article, published: true
        can :destroy, Post do |post|
          post.author == user
        end
        cannot :destroy, Comment
        can :read, Report if user.posts.count > 3
        case user.plan
        when "pro" then can :export, Report
        end
        member_rules(user)
      end

      def member_rules(user)
        can [:read, :create], Comment if user.member?
      end

      def moderator_rules(user)
        return unless user.moderator?
        can :hide, Comment
      end

      def visitor_rules(user)
        return if user.banned?
        can :flag, Comment
      end
    end
  RUBY

  Dir.mktmpdir do |dir|
    path = File.join(dir, "ability.rb")
    File.write(path, FIXTURE)
    rules = CurrentScopeMigrate::AbilityInventory.new(path).run[:rules]
    find = ->(frag) { rules.find { |r| r[:source]&.start_with?(frag) } }
    expected = {
      "can :manage, :all" => "pure_role",
      "can :read, Post" => "pure_role",         # modifier-if, user-only guard
      "can :update, Post," => "ownership",
      "can :read, Article," => "unparseable",   # attribute condition (ABAC)
      "can :destroy, Post do" => "unparseable", # block
      "cannot :destroy" => "unparseable",       # subtractive
      "can :read, Report" => "unparseable",     # quota guard (user.posts.count > 3)
      "can :export, Report" => "unparseable",   # case container
      "can [:read, :create]" => "pure_role",    # helper method, user-only guard
      # guard-clause returns become implicit guards for following statements:
      # `return unless user.moderator?` is provable; `return if user.banned?`
      # leaves a negation, which is not a role predicate (fail closed).
      "can :hide, Comment" => "pure_role",
      "can :flag, Comment" => "unparseable"
    }
    failures = expected.reject { |frag, bucket| find.call(frag)&.dig(:bucket) == bucket }
    # The full_access shape must be called out, and guards captured.
    failures["manage detail"] = true unless
      find.call("can :manage, :all")&.dig(:detail)&.include?("full_access")
    failures["editor guard"] = true unless
      find.call("can :read, Post")&.dig(:guards)&.include?('user.role == "editor"')
    failures["guard-clause guard captured"] = true unless
      find.call("can :hide, Comment")&.dig(:guards)&.include?("user.moderator?")
    if failures.empty?
      puts "self-test OK (#{expected.size} classifications)"
    else
      failures.each_key { |k| warn "FAIL #{k}" }
      exit 1
    end
  end
else
  path = ARGV.first || "app/models/ability.rb"
  abort "No such file: #{path}" unless File.exist?(path)
  puts JSON.pretty_generate(CurrentScopeMigrate::AbilityInventory.new(path).run)
end
