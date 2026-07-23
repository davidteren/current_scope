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

begin
  require "prism"
rescue LoadError
  abort "prism is required (bundled with Ruby >= 3.3; on 3.2 add `gem \"prism\"`)."
end

module CurrentScopeMigrate
  class PolicyInventory
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

    def error_result(path, parse)
      Result.new(file: path, policy_class: nil, method: nil, line: 1,
                 bucket: "unparseable", source: nil,
                 detail: "syntax error: #{parse.errors.first&.message}")
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

    def inventory_class(class_node, class_name, path, source)
      body = class_node.body
      return [] unless body.respond_to?(:body)

      defs = body.body.grep(Prism::DefNode)
      scope_results = scope_class(body).map { |n| classify_scope(n, class_name, path, source) }
      predicate_results = defs.select { |d| d.name.end_with?("?") }.map do |d|
        classify_predicate(d, defs, class_name, path, source)
      end
      predicate_results + scope_results.compact
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

      [ "unparseable", "mixed condition (#{left[0]} #{right[0] == left[0] ? '' : "vs #{right[0]}"})".strip ]
    end

    def classify_call(node, method_name, sibling_defs)
      if %i[== !=].include?(node.name) && node.arguments&.arguments&.size == 1
        return classify_comparison(node, method_name)
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
    # other objects). `user.admin?`, `user.role == ...` chains qualify.
    def user_only?(node)
      case node
      when Prism::CallNode
        return false if node.name == :record || receiver_root(node) == :record

        receiver = node.receiver
        receiver.nil? ? node.name == :user : user_only?(receiver)
      when nil
        false
      else
        literal?(node)
      end
    end

    def receiver_root(node)
      current = node
      current = current.receiver while current.is_a?(Prism::CallNode) && current.receiver
      current.is_a?(Prism::CallNode) ? current.name : nil
    end

    def bare_call?(node, name)
      node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == name
    end

    def literal?(node)
      node.is_a?(Prism::StringNode) || node.is_a?(Prism::SymbolNode) ||
        node.is_a?(Prism::IntegerNode) || node.is_a?(Prism::TrueNode) ||
        node.is_a?(Prism::FalseNode) || node.is_a?(Prism::NilNode)
    end

    # --- Scope#resolve classification --------------------------------------

    def classify_scope(scope_node, class_name, path, source)
      resolve = scope_node.body&.body.to_a.grep(Prism::DefNode).find { |d| d.name == :resolve }
      return nil unless resolve

      body = single_expression(resolve)
      bucket, detail =
        if body && bare_call?(body.receiver, :scope) && body.is_a?(Prism::CallNode) && body.name == :all
          [ "pure_role", "scope.all — org-wide visibility, matches an org-wide grant" ]
        elsif body && where_on_scope_with_user?(body)
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
      def archive?
        log_check
        user.admin?
      end

      class Scope < Scope
        def resolve = scope.where(author_id: user.id)
      end
    end
  RUBY

  Dir.mktmpdir do |dir|
    File.write(File.join(dir, "post_policy.rb"), FIXTURE)
    rows = CurrentScopeMigrate::PolicyInventory.new(dir).run[:policies]
    expected = {
      "index?" => "pure_role", "show?" => "pure_role", "create?" => "pure_role",
      "update?" => "ownership", "approve?" => "sod_shape", "destroy?" => "unparseable",
      "edit?" => "unparseable", "archive?" => "unparseable", "resolve" => "ownership"
    }
    failures = expected.reject do |meth, bucket|
      rows.any? { |r| r[:method] == meth && r[:bucket] == bucket }
    end
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
