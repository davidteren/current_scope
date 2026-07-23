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
require_relative "ast_helpers"

begin
  require "prism"
rescue LoadError
  abort "prism is required (bundled with Ruby >= 3.3; on 3.2 add `gem \"prism\"`)."
end

module CurrentScopeMigrate
  class AbilityInventory
    include AstHelpers

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
      methods = [] # [ [class_name, def_node], ... ]
      each_ability_method(parse.value) { |klass, def_node| methods << [ klass, def_node ] }
      # Class-scoped keys ("Ability#admin_rules") so several *Ability classes
      # in one file can never contaminate each other's guard chains.
      names_by_class = Hash.new { |h, k| h[k] = Set.new }
      methods.each { |klass, d| names_by_class[klass] << d.name.to_s }

      # Pass 1: classify every rule AND record each intra-class helper CALL
      # SITE ('admin_rules(user) if user.admin?') as {caller:, guards:}.
      @call_sites = Hash.new { |h, k| h[k] = [] }
      @rule_keys = {}
      methods.each do |klass, def_node|
        key = "#{klass}##{def_node.name}"
        walk_method(def_node.body, key, [], rules, names_by_class[klass], klass)
      end

      # Pass 2: a helper's rules inherit its callers' EFFECTIVE guards,
      # transitively (a helper called from an admin-gated helper carries the
      # admin gate too). Ambiguity — differing chains, cycles — fails closed.
      rules.each do |rule|
        key = @rule_keys[rule.object_id]
        chain = effective_guards(key)
        next if chain == [] # a root (initialize) or an uncalled helper

        if chain == :ambiguous
          rule.bucket = "unparseable"
          rule.detail = "helper invoked from differing/cyclic call-site guard chains — " \
                        "decide which audience applies by hand"
        else
          rule.guards = chain.map { |g| g[:source] } + rule.guards
          if chain.any? { |g| !g[:user_only] } && rule.bucket != "unparseable"
            rule.bucket = "unparseable"
            rule.detail = "called under a guard that is not provably user-only " \
                          "(#{chain.reject { |g| g[:user_only] }.map { |g| g[:source] }.join('; ')})"
          end
        end
      end

      { rules: rules.map(&:to_h) }
    end

    private

    # Every instance method of a class named *Ability (or including
    # CanCan::Ability) can define rules — initialize commonly delegates to
    # role-named helper methods. Yields (class_name, def_node).
    def each_ability_method(node, current_class = nil, &blk)
      if node.is_a?(Prism::ClassNode)
        name = node.constant_path.respond_to?(:full_name) ? node.constant_path.full_name : node.constant_path.slice.to_s
        current_class = (name.end_with?("Ability") || includes_cancan?(node)) ? name : nil
      end
      yield current_class, node if current_class && node.is_a?(Prism::DefNode)
      return unless node.respond_to?(:child_nodes)

      node.child_nodes.compact.each { |c| each_ability_method(c, current_class, &blk) }
    end

    # Resolve a method's inherited guard chain to fixpoint. Returns [] for
    # roots/uncalled helpers, :ambiguous for differing chains or cycles.
    def effective_guards(key, seen = Set.new)
      @effective ||= {}
      return @effective[key] if @effective.key?(key)
      return :ambiguous if seen.include?(key) # cycle — not provable

      sites = @call_sites[key]
      return @effective[key] = [] if key.end_with?("#initialize") || sites.empty?

      chains = sites.map do |site|
        caller_chain = effective_guards(site[:caller], seen + [ key ])
        next :ambiguous if caller_chain == :ambiguous

        caller_chain + site[:guards]
      end.uniq
      @effective[key] = (chains.size == 1 && chains.first != :ambiguous) ? chains.first : :ambiguous
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
    def walk_method(node, method_name, guards, rules, method_names, klass = nil)
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
          walk_method(stmt, method_name, guards + implicit, rules, method_names, klass)
          implicit += implicit_guards_from(stmt)
        end
      when Prism::IfNode, Prism::UnlessNode
        # The guard carries its SIGN: `unless user.guest?` guards its body
        # with !(user.guest?) — serializing the bare predicate would read as
        # the inverted audience ("grant TO guests"). A negated user-only
        # predicate is still user-only (the audience is defined purely from
        # user attributes), matching the policy classifier's treatment of
        # `!user.admin?`.
        inner_ok = user_only?(node.predicate)
        pred_src = slice(node.predicate)
        positive = { source: pred_src, user_only: inner_ok }
        negative = { source: "!(#{pred_src})", user_only: inner_ok }
        body_guard, arm_guard = node.is_a?(Prism::UnlessNode) ? [ negative, positive ] : [ positive, negative ]
        walk_method(node.statements, method_name, guards + [ body_guard ], rules, method_names, klass)
        if (arm = else_arm(node))
          walk_method(arm, method_name, guards + [ arm_guard ], rules, method_names, klass)
        end
      when Prism::CallNode
        bare_or_self = node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)
        if bare_or_self && %i[can cannot].include?(node.name)
          rule = classify_rule(node, method_name, guards)
          @rule_keys[rule.object_id] = method_name
          rules << rule
        elsif bare_or_self && node.name == :alias_action
          alias_row = Result.new(file: @path, method: method_name, line: node.location.start_line,
                              bucket: "unparseable", source: slice(node),
                              guards: guards.map { |g| g[:source] },
                              detail: "custom alias_action — expand affected rules' actions " \
                                      "through this alias by hand when mapping keys")
          @rule_keys[alias_row.object_id] = method_name
          rules << alias_row
        elsif bare_or_self && method_names.include?(node.name.to_s)
          # Intra-class helper call (bare or self.) — its rules inherit THESE
          # guards (pass 2). A helper handed anything other than the user (or
          # nothing) may authorize a DIFFERENT subject: poison the chain.
          site_guards = guards
          unless (node.arguments&.arguments || []).all? { |a| user_chain?(a) || literal?(a) }
            site_guards = guards + [ { source: "(helper called with non-user arguments)", user_only: false } ]
          end
          @call_sites["#{klass}##{node.name}"] << { caller: method_name, guards: site_guards }
        end
        node.child_nodes.compact.each { |c| walk_method(c, method_name, guards, rules, method_names, klass) }
      when Prism::CaseNode, Prism::CaseMatchNode, Prism::WhileNode, Prism::UntilNode,
           Prism::RescueNode, Prism::BeginNode, Prism::BlockNode, Prism::ForNode,
           Prism::LambdaNode
        # Containers whose conditions we do not model: everything inside is
        # guarded by something unprovable.
        poison = { source: "(#{node.class.name.split('::').last} container)", user_only: false }
        node.child_nodes.compact.each { |c| walk_method(c, method_name, guards + [ poison ], rules, method_names, klass) }
      else
        node.child_nodes.compact.each { |c| walk_method(c, method_name, guards, rules, method_names, klass) } if node.respond_to?(:child_nodes)
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
      # The arm terminates when its LAST statement does — side-effect lines
      # before the return (logging, counters) don't change control flow, and
      # requiring all-terminators would silently drop the guard for the
      # statements that follow (a fail-open in the report).
      last = body.last
      terminates = last && (TERMINATORS.any? { |t| last.is_a?(t) } ||
                            (last.is_a?(Prism::CallNode) && last.receiver.nil? && last.name == :raise))
      return [] unless terminates

      inner_ok = user_only?(stmt.predicate)
      if stmt.is_a?(Prism::UnlessNode)
        # `return unless P` — the rest runs when P holds.
        [ { source: slice(stmt.predicate), user_only: inner_ok } ]
      else
        # `return if P` — the rest runs when P does NOT hold; the negation
        # of a user-only predicate is still user-only.
        [ { source: "!(#{slice(stmt.predicate)})", user_only: inner_ok } ]
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

        # user_chain? proves the root; user_only? proves nothing else is
        # smuggled in (user.id(record) must never read as ownership).
        if user_chain?(el.value) && user_only?(el.value)
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
        (receiver_root(node) == :user || bare_call?(node, :user))
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
        admin_extra(user) if user.admin?
        shared_rules(user) if user.admin?
        shared_rules(user) if user.billing?
        self.selfish_rules(user) if user.ops?
        proxy_rules(User.new) if user.admin?
        [1].each { can :loop_read, Post }
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

      def guest_rules(user)
        can :browse, Post unless user.guest?
      end

      def admin_extra(user)
        can :configure, Report
        nested_extra(user)
      end

      def nested_extra(user)
        can :deep_configure, Report
      end

      def selfish_rules(user)
        can :operate, Report
      end

      def proxy_rules(user)
        can :proxy, Report
      end

      def shared_rules(user)
        can :share, Report
      end

      def audited_rules(user)
        unless user.staff?
          Rails.logger.info("non-staff ability request")
          return
        end
        can :audit, Report
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
      # guard-clause returns become implicit guards for following statements;
      # a negated user-only predicate is still user-only, with the sign kept
      # in the serialized guard.
      "can :hide, Comment" => "pure_role",
      "can :flag, Comment" => "pure_role",
      "can :browse, Post" => "pure_role",
      # a side-effect line before the guard-clause return must not drop the
      # guard (the arm still terminates)
      "can :audit, Report" => "pure_role",
      # helper called under ONE guard inherits it; helper called from two
      # sites with differing guards is not provable (fail closed)
      "can :configure, Report" => "pure_role",
      "can :share, Report" => "unparseable",
      # transitive inheritance: nested_extra inherits admin_extra's caller guard
      "can :deep_configure, Report" => "pure_role",
      # self.-receiver helper calls count as call sites
      "can :operate, Report" => "pure_role",
      # a helper handed something other than the user poisons the chain
      "can :proxy, Report" => "unparseable",
      # rules inside iterator blocks are not provably executed
      "can :loop_read, Post" => "unparseable"
    }
    failures = expected.reject { |frag, bucket| find.call(frag)&.dig(:bucket) == bucket }
    # The full_access shape must be called out, and guards captured.
    failures["manage detail"] = true unless
      find.call("can :manage, :all")&.dig(:detail)&.include?("full_access")
    failures["editor guard"] = true unless
      find.call("can :read, Post")&.dig(:guards)&.include?('user.role == "editor"')
    failures["guard-clause guard captured"] = true unless
      find.call("can :hide, Comment")&.dig(:guards)&.include?("user.moderator?")
    # Guard SIGNS must be serialized — an unsigned unless-guard reads as the
    # inverted audience.
    failures["negated return-if guard signed"] = true unless
      find.call("can :flag, Comment")&.dig(:guards)&.include?("!(user.banned?)")
    failures["unless-modifier guard signed"] = true unless
      find.call("can :browse, Post")&.dig(:guards)&.include?("!(user.guest?)")
    failures["side-effect guard clause captured"] = true unless
      find.call("can :audit, Report")&.dig(:guards)&.include?("user.staff?")
    failures["helper call-site guard inherited"] = true unless
      find.call("can :configure, Report")&.dig(:guards)&.include?("user.admin?")
    failures["transitive guard inherited"] = true unless
      find.call("can :deep_configure, Report")&.dig(:guards)&.include?("user.admin?")
    failures["self-call guard inherited"] = true unless
      find.call("can :operate, Report")&.dig(:guards)&.include?("user.ops?")
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
