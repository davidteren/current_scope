# frozen_string_literal: true

# Deterministic Pundit policy inventory for the current-scope-migrate skill.
#
#   ruby policy_inventory.rb app/policies            # JSON inventory to stdout
#   ruby policy_inventory.rb --self-test             # verify the classifier
#
# Honest contract (#45): classify only what the AST can PROVE. Four buckets:
#   pure_role   — predicate reads only `user` (or literals): maps to grid ticks
#   ownership   — single record-vs-user comparison: maps to a scoped role
#   sod_shape   — negated ownership on an approve-like action: propose SoD
#   unparseable — everything else, reported verbatim for a human
# A wrong "pure_role" silently changes who can do what; a wrong "unparseable"
# only costs a human a minute. All ambiguity therefore lands in unparseable.
require "json"
require_relative "ast_helpers"

begin
  require "prism"
rescue LoadError
  abort "prism is required (bundled with Ruby >= 3.3; on 3.2 add `gem \"prism\"`)."
end

module CurrentScopeMigrate
  class PolicyInventory
    include AstHelpers

    APPROVE_LIKE = %w[approve reject publish unpublish confirm sign_off review release].freeze

    Result = Struct.new(:file, :policy_class, :method, :line, :bucket, :source, :detail,
                        keyword_init: true) do
      def to_h = super.compact
    end

    def initialize(policy_dir)
      @policy_dir = policy_dir
    end

    def run
      files = Dir.glob(File.join(@policy_dir, "**", "*_policy.rb")).sort
      results = files.flat_map { |f| inventory_file(f) }
      { policies: results.map(&:to_h), files_scanned: files.size }
    end

    def inventory_file(path)
      parse = Prism.parse_file(path)
      return [ error_result(path, parse) ] unless parse.success?

      source = parse.source.source
      collect_classes(parse.value).flat_map do |class_node, class_name|
        next [] unless class_name.end_with?("Policy")

        inventory_class(class_node, class_name, path, source)
      end
    end

    private

    # A syntax error is fail-closed AND reviewable: cite the real error line
    # and quote it, honoring the file:line + verbatim-source contract.
    def error_result(path, parse)
      err = parse.errors.first
      line = err&.location&.start_line || 1
      source_line = parse.source.source.lines[line - 1]&.strip
      Result.new(file: path, policy_class: nil, method: nil, line: line,
                 bucket: "unparseable", source: source_line,
                 detail: "syntax error: #{err&.message}")
    end

    # [[class_node, "Admin::PostPolicy"], ...] — walks module nesting.
    def collect_classes(node, namespace = [], acc = [])
      case node
      when Prism::ClassNode
        name = (namespace + [ const_name(node.constant_path) ]).join("::")
        acc << [ node, name ]
        collect_classes(node.body, namespace + [ const_name(node.constant_path) ], acc) if node.body
      when Prism::ModuleNode
        collect_classes(node.body, namespace + [ const_name(node.constant_path) ], acc) if node.body
      else
        node.child_nodes.compact.each { |c| collect_classes(c, namespace, acc) } if node.respond_to?(:child_nodes)
      end
      acc
    end

    def const_name(constant_path)
      constant_path.respond_to?(:full_name) ? constant_path.full_name : constant_path.slice
    end

    # Action Policy class-level DSL calls: constructs a grid mapping cannot
    # represent mechanically — each is reported for a human. relation_scope
    # is handled separately (it IS classifiable).
    AP_DSL = %i[pre_check alias_rule default_rule authorize scope_matcher].freeze

    def inventory_class(class_node, class_name, path, source)
      body = class_node.body
      return [] unless body.respond_to?(:body)

      defs = body.body.grep(Prism::DefNode)
      scope_results = scope_class(body).map { |n| classify_scope(n, class_name, path, source) }
      predicate_results = defs.select { |d| d.name.end_with?("?") }.map do |d|
        classify_predicate(d, defs, class_name, path, source)
      end
      predicate_results + scope_results.compact +
        action_policy_dsl(body, class_name, path, source) +
        relation_scopes(body, class_name, path, source)
    end

    # Action Policy `relation_scope do |relation| ... end` — the AP analogue
    # of a Pundit Scope#resolve; classify its block body the same way, with
    # the block parameter standing in for `scope`.
    def relation_scopes(class_body, class_name, path, source)
      class_body.body.grep(Prism::CallNode).select { |c| c.name == :relation_scope && c.block }.map do |call|
        block = call.block
        param = block.respond_to?(:parameters) &&
                block.parameters&.parameters&.requireds&.first&.name
        body = block.body.is_a?(Prism::StatementsNode) && block.body.body.size == 1 ? block.body.body.first : nil
        bucket, detail =
          if param.nil? || body.nil?
            [ "unparseable", "relation_scope body not provable" ]
          elsif body.is_a?(Prism::CallNode) && body.name == :all && rooted_at?(body.receiver, param)
            [ "pure_role", "#{param}.all — org-wide visibility, matches an org-wide grant" ]
          elsif body.is_a?(Prism::CallNode) && body.name == :where && rooted_at?(body.receiver, param) &&
                user_bound_hash?(body.arguments&.arguments&.first)
            [ "ownership", "#{param}.where(<fk>: user...) — matches scope_for over scoped grants" ]
          else
            [ "unparseable", "relation_scope body not provable" ]
          end
        Result.new(file: path, policy_class: class_name, method: "relation_scope",
                   line: call.location.start_line, bucket: bucket,
                   source: slice(call, source), detail: detail)
      end
    end

    def rooted_at?(node, param_name)
      bare_call?(node, param_name&.to_sym) ||
        (node.is_a?(Prism::LocalVariableReadNode) && node.name == param_name)
    end

    def user_bound_hash?(kwargs)
      return false unless kwargs.is_a?(Prism::KeywordHashNode) || kwargs.is_a?(Prism::HashNode)

      kwargs.elements.all? { |a| a.is_a?(Prism::AssocNode) && user_chain?(a.value) }
    end

    def action_policy_dsl(class_body, class_name, path, source)
      class_body.body.grep(Prism::CallNode).select { |c| c.receiver.nil? && AP_DSL.include?(c.name) }.map do |call|
        Result.new(file: path, policy_class: class_name, method: call.name.to_s,
                   line: call.location.start_line, bucket: "unparseable",
                   source: slice(call, source),
                   detail: "Action Policy #{call.name} — no mechanical grid equivalent; " \
                           "fold its effect into each affected predicate's mapping by hand")
      end
    end

    def scope_class(class_body)
      class_body.body.grep(Prism::ClassNode).select { |c| const_name(c.constant_path) == "Scope" }
    end

    # --- predicate classification ------------------------------------------

    def classify_predicate(def_node, sibling_defs, class_name, path, source)
      body = single_expression(def_node)
      bucket, detail =
        if body.nil?
          [ "unparseable", "multi-statement or empty body" ]
        else
          classify_expression(body, def_node.name.to_s, sibling_defs)
        end

      Result.new(file: path, policy_class: class_name, method: def_node.name.to_s,
                 line: def_node.location.start_line, bucket: bucket,
                 source: slice(def_node, source), detail: detail)
    end

    # The def's body only when it is exactly one expression; nil otherwise.
    def single_expression(def_node)
      body = def_node.body
      return body unless body.is_a?(Prism::StatementsNode)

      body.body.size == 1 ? body.body.first : nil
    end

    def classify_expression(node, method_name, sibling_defs)
      case node
      when Prism::TrueNode
        [ "pure_role", "always true — a baseline permission every role ticks" ]
      when Prism::FalseNode
        [ "pure_role", "always false — tick it on no role" ]
      when Prism::AndNode, Prism::OrNode
        combine(classify_expression(node.left, method_name, sibling_defs),
                classify_expression(node.right, method_name, sibling_defs))
      when Prism::CallNode
        classify_call(node, method_name, sibling_defs)
      else
        [ "unparseable", "expression shape not provable (#{node.class.name.split('::').last})" ]
      end
    end

    # Both sides pure_role => pure_role; anything else is not provable as a
    # single grid tick (an ownership arm inside || is a partial-scope rule).
    def combine(left, right)
      return [ "pure_role", "boolean combination of role predicates" ] if
        left[0] == "pure_role" && right[0] == "pure_role"

      kinds = [ left[0], right[0] ].uniq.join(" vs ")
      [ "unparseable", "mixed condition (#{kinds})" ]
    end

    # Ordering comparisons are quota / time-window conditions (ABAC), not role
    # membership — a static grid tick would freeze a per-request condition.
    ORDERING_OPS = %i[< > <= >= <=> =~ !~].freeze

    def classify_call(node, method_name, sibling_defs)
      if %i[== !=].include?(node.name) && node.arguments&.arguments&.size == 1
        return classify_comparison(node, method_name)
      end
      if ORDERING_OPS.include?(node.name)
        return [ "unparseable", "ordering comparison (#{node.name}) — a quota/time condition, not a role" ]
      end
      if node.name == :! && node.receiver
        inner = classify_expression(node.receiver, method_name, sibling_defs)
        return inner[0] == "pure_role" ? inner : [ "unparseable", "negation of #{inner[0]}" ]
      end
      return [ "pure_role", "user-only predicate" ] if user_only?(node)
      if node.receiver.nil? && sibling_defs.any? { |d| d.name == node.name }
        return [ "unparseable", "delegates to ##{node.name} — classify the target" ]
      end

      [ "unparseable", "call not provable (#{node.name})" ]
    end

    def classify_comparison(node, method_name)
      lhs = node.receiver
      rhs = node.arguments.arguments.first
      return [ "unparseable", "comparison operands not provable" ] unless lhs && rhs

      if ownership_pair?(lhs, rhs)
        if node.name == :!= && APPROVE_LIKE.include?(method_name.delete_suffix("?"))
          [ "sod_shape",
           "initiator-cannot-act on an approve-like action — propose config.sod_actions " \
           "+ current_scope_initiator instead of a hand-rolled check" ]
        elsif node.name == :==
          [ "ownership", "record-vs-user comparison — maps to a scoped role " \
                        "(backfill + grant-on-create hook, review required)" ]
        else
          [ "unparseable", "record-vs-user != outside approve-like actions" ]
        end
      elsif user_only?(lhs) && literal?(rhs)
        [ "pure_role", "user attribute vs literal" ]
      else
        [ "unparseable", "comparison not provable" ]
      end
    end

    # record.author == user | record.author_id == user.id | user == record.author
    def ownership_pair?(lhs, rhs)
      (record_chain?(lhs) && user_chain?(rhs)) || (user_chain?(lhs) && record_chain?(rhs))
    end

    def record_chain?(node)
      node.is_a?(Prism::CallNode) && receiver_root(node) == :record
    end

    def user_chain?(node)
      return true if bare_call?(node, :user)

      node.is_a?(Prism::CallNode) && receiver_root(node) == :user
    end

    # Every leaf receiver in the call chain must be `user` (no record, no
    # other objects) — AND every argument must itself be user-only or a
    # literal, and there must be no block. Without the argument/block check,
    # `user.widgets.include?(record)` would classify pure_role while
    # depending on the record: a fail-open misclassification.
    def user_only?(node)
      case node
      when Prism::CallNode
        return false if node.name == :record || receiver_root(node) == :record
        return false if node.block
        return false unless (node.arguments&.arguments || []).all? { |a| user_only?(a) }

        receiver = node.receiver
        case receiver
        when nil then node.name == :user
        when Prism::CallNode then user_only?(receiver)
        # A method on a literal (30.days.ago) is a computation, not a user
        # attribute — time/constant-dependent, so not provable as a role.
        else false
        end
      when nil
        false
      else
        literal?(node)
      end
    end

    # --- Scope#resolve classification --------------------------------------

    def classify_scope(scope_node, class_name, path, source)
      resolve = scope_node.body&.body.to_a.grep(Prism::DefNode).find { |d| d.name == :resolve }
      return nil unless resolve

      body = single_expression(resolve)
      # Type check BEFORE touching .receiver — a conditional resolve body
      # (IfNode etc.) has no receiver and must land in unparseable, not crash.
      bucket, detail =
        if body.is_a?(Prism::CallNode) && body.name == :all && bare_call?(body.receiver, :scope)
          [ "pure_role", "scope.all — org-wide visibility, matches an org-wide grant" ]
        elsif body.is_a?(Prism::CallNode) && where_on_scope_with_user?(body)
          [ "ownership", "scope.where(<fk>: user...) — matches scope_for over scoped grants" ]
        else
          [ "unparseable", "resolve body not provable" ]
        end
      Result.new(file: path, policy_class: "#{class_name}::Scope", method: "resolve",
                 line: resolve.location.start_line, bucket: bucket,
                 source: slice(resolve, source), detail: detail)
    end

    def where_on_scope_with_user?(node)
      return false unless node.is_a?(Prism::CallNode) && node.name == :where
      return false unless bare_call?(node.receiver, :scope)

      kwargs = node.arguments&.arguments&.first
      return false unless kwargs.is_a?(Prism::KeywordHashNode) || kwargs.is_a?(Prism::HashNode)

      kwargs.elements.all? { |a| a.is_a?(Prism::AssocNode) && user_chain?(a.value) }
    end

    def slice(node, source)
      source[node.location.start_offset...node.location.end_offset]
    end
  end
end

# --- self-test --------------------------------------------------------------

if ARGV.first == "--self-test"
  require "tmpdir"
  FIXTURE = <<~RUBY
    class PostPolicy < ApplicationPolicy
      def index? = true
      def show? = user.admin? || user.moderator?
      def create? = user.role == "editor"
      def update? = record.author_id == user.id
      def approve? = record.requested_by != user
      def destroy? = record.published_at.nil?
      def edit? = update?
      def review? = user.widgets.include?(record)
      def audit? = user.admin?(record.id)
      def flag? = user.roles.any? { |r| r.name == record.owner_role }
      def export? = user.role.in?(%w[admin editor])
      def mixed? = user.admin? || record.owner == user
      def blocked? = !user.admin?
      def safe_nav? = user&.admin?
      def both? = user.admin? && user.active?
      def recent? = user.created_at > 30.days.ago
      def quota? = user.posts_count < 10
      def archive?
        log_check
        user.admin?
      end

      class Scope < Scope
        def resolve = scope.where(author_id: user.id)
      end
    end

    class CommentPolicy < ApplicationPolicy
      class Scope < Scope
        def resolve = scope.where("author_id = ?", user.id)
      end
    end

    class ThingPolicy < ApplicationPolicy
      class Scope < Scope
        def resolve
          if user.admin?
            scope.all
          else
            scope.where(owner_id: user.id)
          end
        end
      end
    end

    class NotePolicy < ApplicationPolicy
      pre_check :allow_admins
      alias_rule :edit?, to: :update?

      relation_scope do |relation|
        relation.where(owner_id: user.id)
      end
    end

    class WidePolicy < ApplicationPolicy
      relation_scope do |relation|
        relation.all
      end
    end
  RUBY

  BROKEN = "class BrokenPolicy < ApplicationPolicy\n  def oops? = (\nend\n"

  Dir.mktmpdir do |dir|
    File.write(File.join(dir, "post_policy.rb"), FIXTURE)
    File.write(File.join(dir, "broken_policy.rb"), BROKEN)
    rows = CurrentScopeMigrate::PolicyInventory.new(dir).run[:policies]
    expected = {
      "index?" => "pure_role", "show?" => "pure_role", "create?" => "pure_role",
      "update?" => "ownership", "approve?" => "sod_shape", "destroy?" => "unparseable",
      "edit?" => "unparseable", "archive?" => "unparseable",
      # fail-closed regressions: record smuggled through arguments or blocks
      "review?" => "unparseable", "audit?" => "unparseable", "flag?" => "unparseable",
      # literal-array arguments stay provable; so are !, &&, and safe-nav
      # chains that stay user-only
      "export?" => "pure_role", "blocked?" => "pure_role",
      "safe_nav?" => "pure_role", "both?" => "pure_role",
      # a pure_role arm ORed with an ownership arm is NOT provable as either
      "mixed?" => "unparseable",
      # ordering comparisons are quota/time conditions, never a role
      "recent?" => "unparseable", "quota?" => "unparseable"
    }
    failures = expected.reject do |meth, bucket|
      rows.any? { |r| r[:method] == meth && r[:bucket] == bucket }
    end
    # Scope classifications collide on the method name, so assert by class.
    scope_expected = {
      "PostPolicy::Scope" => "ownership",      # scope.where(author_id: user.id)
      "CommentPolicy::Scope" => "unparseable", # string-SQL where — not provable
      "ThingPolicy::Scope" => "unparseable"    # conditional body — must not crash
    }
    # Action Policy constructs: relation_scope classifies; DSL calls flag.
    ap_expected = [
      [ "NotePolicy", "relation_scope", "ownership" ],
      [ "WidePolicy", "relation_scope", "pure_role" ],
      [ "NotePolicy", "pre_check", "unparseable" ],
      [ "NotePolicy", "alias_rule", "unparseable" ]
    ]
    ap_expected.each do |klass, meth, bucket|
      next if rows.any? { |r| r[:policy_class] == klass && r[:method] == meth && r[:bucket] == bucket }

      failures["#{klass}##{meth}"] = bucket
    end
    failures = failures.to_h.merge(scope_expected.reject { |klass, bucket|
      rows.any? { |r| r[:policy_class] == klass && r[:method] == "resolve" && r[:bucket] == bucket }
    })
    failures["broken file"] = "unparseable" unless
      rows.any? { |r| r[:bucket] == "unparseable" && r[:detail].to_s.start_with?("syntax error") }
    if failures.empty?
      puts "self-test OK (#{expected.size} classifications)"
    else
      failures.each do |meth, bucket|
        actual = rows.find { |r| r[:method] == meth }
        warn "FAIL #{meth}: expected #{bucket}, got #{actual ? actual[:bucket] : 'missing'}"
      end
      exit 1
    end
  end
else
  dir = ARGV.first || "app/policies"
  abort "No such directory: #{dir}" unless Dir.exist?(dir)
  puts JSON.pretty_generate(CurrentScopeMigrate::PolicyInventory.new(dir).run)
end
