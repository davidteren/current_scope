# frozen_string_literal: true

# Deterministic Pundit call-site rewriter (#45 phase 2).
#
#   ruby callsite_rewrite.rb app                # JSON report to stdout (default: report-only)
#   ruby callsite_rewrite.rb --write app        # apply the safe rewrites in place
#   ruby callsite_rewrite.rb --self-test        # verify the rewriter
#
# Honest contract: rewrite only the shapes the AST proves are mechanical.
#   authorize @x            (statement position, 1 arg)  -> delete (Guard gates it)
#   policy(@x).update?      (predicate on policy call)   -> allowed_to?(:update, @x)
#   policy_scope(X)         (1 arg)                      -> scope_for(X)
# Everything else — value-used authorize, custom query args, blocks,
# permitted_attributes, ERB templates — is REPORTED with file:line for a
# human, never guessed at. Report-only is the default; --write applies.
require "json"
require "set"

begin
  require "prism"
rescue LoadError
  abort "prism is required (bundled with Ruby >= 3.3; on 3.2 add `gem \"prism\"`)."
end

module CurrentScopeMigrate
  class CallsiteRewrite
    Edit = Struct.new(:file, :line, :kind, :original, :replacement, :start_offset, :end_offset,
                      keyword_init: true)
    Review = Struct.new(:file, :line, :kind, :source, :note, keyword_init: true)

    # Scan-apply to fixpoint: apply! only takes outermost edits, so nested
    # rewrites (policy(policy_scope(X)).foo?) surface on the next scan.
    # Returns the final report with all edits applied across passes.
    MAX_PASSES = 5 # nesting depth bound for the scan-apply fixpoint

    def self.rewrite_all!(dir)
      all_edits = []
      reviews = []
      MAX_PASSES.times do
        rw = new(dir).scan
        reviews = rw.reviews
        break if rw.edits.empty?

        rw.apply!
        all_edits.concat(rw.edits)
      end
      # Honest convergence claim: a fresh scan must find nothing left.
      converged = new(dir).scan.edits.empty?
      deduped = all_edits.uniq { |e| [ e.file, e.line, e.original, e.kind ] }
      { rewrites: deduped.map { |e| e.to_h.except(:start_offset, :end_offset) },
        reviews: reviews.map(&:to_h),
        counts: { rewrites: deduped.size, reviews: reviews.size },
        applied: true, converged: converged }
    end

    def initialize(dir)
      @dir = dir
      @edits = []
      @reviews = []
    end

    attr_reader :edits, :reviews

    TEMPLATE_GLOB = "*.{erb,haml,slim,jbuilder}"

    def scan
      Dir.glob(File.join(@dir, "**", "*.rb")).sort.each { |f| scan_ruby(f) }
      Dir.glob(File.join(@dir, "**", TEMPLATE_GLOB)).sort.each { |f| scan_template(f) }
      self
    end

    # Applies only OUTERMOST edits: an edit nested inside another edit's span
    # would have its offsets invalidated by the outer replacement (and the
    # outer replacement is built from the original source, so applying both
    # corrupts the file). Callers rescan until no edits remain (see --write),
    # which picks up rewrites that were nested on the previous pass.
    def apply!
      edits.group_by(&:file).each do |file, file_edits|
        source = File.read(file)
        outermost = file_edits.reject do |e|
          file_edits.any? do |other|
            !other.equal?(e) && other.start_offset <= e.start_offset &&
              e.end_offset <= other.end_offset
          end
        end
        # Bottom-up so earlier offsets stay valid.
        outermost.sort_by(&:start_offset).reverse_each do |e|
          source[e.start_offset...e.end_offset] = e.replacement
        end
        File.write(file, source)
      end
      self
    end

    def report
      { rewrites: edits.map { |e| e.to_h.except(:start_offset, :end_offset) },
        reviews: reviews.map(&:to_h),
        counts: { rewrites: edits.size, reviews: reviews.size } }
    end

    private

    def scan_ruby(path)
      parse = Prism.parse_file(path)
      unless parse.success?
        @reviews << Review.new(file: path, line: parse.errors.first&.location&.start_line || 1,
                               kind: "syntax_error", source: nil,
                               note: "file does not parse: #{parse.errors.first&.message}")
        return
      end
      # A file that skips the permission gate makes `authorize` its ONLY
      # check — deleting it there removes authorization entirely. Any skip
      # in the file (even with only:/except:) downgrades every deletion to
      # a review: fail-closed.
      @file_gate_skipped = gate_skipped?(parse.value)
      @public_action_defs = collect_public_controller_defs(parse.value)
      walk(parse.value, nil, nil, path, parse.source.source)
    end

    # DefNodes that are PUBLIC members of a *Controller class — Rails ignores
    # an action's return value, so a trailing authorize there is provably
    # value-unused. Private/protected defs and non-controller classes are not.
    def collect_public_controller_defs(node, acc = Set.new)
      if node.is_a?(Prism::ClassNode) &&
         const_name(node.constant_path).end_with?("Controller") &&
         node.body.respond_to?(:body)
        visibility = :public
        node.body.body.each do |child|
          case child
          when Prism::CallNode
            visibility = child.name if child.receiver.nil? &&
                                      %i[private protected].include?(child.name) &&
                                      child.arguments.nil?
          when Prism::DefNode
            acc << child.object_id if visibility == :public
          end
        end
      end
      node.child_nodes.compact.each { |c| collect_public_controller_defs(c, acc) } if node.respond_to?(:child_nodes)
      acc
    end

    def const_name(constant_path)
      constant_path.respond_to?(:full_name) ? constant_path.full_name : constant_path.slice.to_s
    end

    def gate_skipped?(node)
      if node.is_a?(Prism::CallNode) && node.name == :skip_before_action
        args = node.arguments&.arguments || []
        # Fail closed: symbol OR string forms name the gate; any argument we
        # cannot prove is NOT the gate (splat, variable, send) counts as a
        # skip too — a missed skip means deleting a file's only auth check.
        named = args.any? do |a|
          case a
          when Prism::SymbolNode, Prism::StringNode then a.unescaped == "current_scope_check!"
          else false
          end
        end
        unprovable = args.empty? || args.any? { |a| !a.is_a?(Prism::SymbolNode) && !a.is_a?(Prism::StringNode) }
        return true if named || unprovable
      end
      node.respond_to?(:child_nodes) &&
        node.child_nodes.compact.any? { |c| gate_skipped?(c) }
    end

    # View templates (ERB/Haml/Slim/jbuilder) cannot be parsed as plain Ruby
    # here — report occurrences, never rewrite.
    def scan_template(path)
      File.foreach(path).with_index(1) do |text, lineno|
        next unless text =~ /\b(policy_scope|policy|authorize|permitted_attributes)\b/

        @reviews << Review.new(file: path, line: lineno, kind: "template", source: text.strip,
                               note: "view template — rewrite by hand " \
                                     "(policy(x).foo? -> allowed_to?(:foo, x); policy_scope(X) -> scope_for(X))")
      end
    end

    def walk(node, parent, grandparent, path, source)
      classify(node, parent, grandparent, path, source) if node.is_a?(Prism::CallNode)
      node.child_nodes.compact.each { |c| walk(c, node, parent, path, source) }
    end

    def classify(node, parent, grandparent, path, source)
      return unless node.receiver.nil?

      case node.name
      when :authorize then classify_authorize(node, parent, grandparent, path, source)
      when :policy then classify_policy(node, parent, path, source)
      when :policy_scope then classify_policy_scope(node, path, source)
      when :permitted_attributes
        @reviews << Review.new(file: path, line: node.location.start_line,
                               kind: "permitted_attributes", source: slice(node, source),
                               note: "no current_scope equivalent — keep strong params in the controller")
      end
    end

    def classify_authorize(node, parent, grandparent, path, source)
      args = node.arguments&.arguments || []
      line = node.location.start_line
      if @file_gate_skipped
        @reviews << Review.new(file: path, line: line, kind: "authorize",
                               source: slice(node, source),
                               note: "this file skips current_scope_check! — authorize may be " \
                                     "the ONLY check here; do not delete until the gate covers it")
        return
      end
      # Deletion allowlist: the statement must sit DIRECTLY in a def/block/
      # lambda body. Any other statements container (when/in branches, rescue
      # bodies, if/unless arms) is conditional execution — deleting there
      # widens authorization, because the Guard gates unconditionally.
      straight_line = grandparent.is_a?(Prism::DefNode) ||
                      grandparent.is_a?(Prism::BlockNode) ||
                      grandparent.is_a?(Prism::LambdaNode)
      if args.size == 1 && node.block.nil? && parent.is_a?(Prism::StatementsNode) &&
         straight_line && simple_ref?(args.first) &&
         !last_expression?(node, parent, grandparent) && alone_on_line?(node, source)
        del = full_line_span(node, source)
        @edits << Edit.new(file: path, line: line, kind: "delete_authorize",
                           original: slice(node, source), replacement: "",
                           start_offset: del[0], end_offset: del[1])
      else
        note = authorize_review_note(node, args, parent, grandparent)
        @reviews << Review.new(file: path, line: line, kind: "authorize",
                               source: slice(node, source), note: note)
      end
    end

    def authorize_review_note(node, args, parent, grandparent)
      if args.size != 1
        "custom query / extra args — map to the gate key by hand"
      elsif parent.is_a?(Prism::StatementsNode) &&
            !(grandparent.is_a?(Prism::DefNode) || grandparent.is_a?(Prism::BlockNode) ||
              grandparent.is_a?(Prism::LambdaNode))
        "CONDITIONAL authorize (if/unless/case/rescue) — the Guard gates " \
          "unconditionally; the condition is a policy decision, not a deletion"
      elsif !parent.is_a?(Prism::StatementsNode)
        "return value is used — assign the record instead, the Guard gates the action"
      elsif !simple_ref?(args.first)
        "argument has side effects (a lookup/raise the deletion would lose) — " \
          "move the lookup to the record hook, then delete by hand"
      elsif last_expression?(node, parent, grandparent)
        "last expression of its method/block — deleting changes the return value"
      else
        "shares its line with other code — delete by hand"
      end
    end

    # A bare variable/ivar or an argument-less self call: deleting the
    # statement provably discards no side effects. `authorize Post.find(...)`
    # performs a lookup (implicit 404) the deletion would silently lose.
    def simple_ref?(node)
      case node
      when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode then true
      when Prism::CallNode
        node.receiver.nil? && node.arguments.nil? && node.block.nil?
      else
        false
      end
    end

    # The last statement of a def/block body is that method's return value —
    # EXCEPT a public controller action, whose return Rails ignores.
    def last_expression?(node, parent, grandparent)
      return false unless parent.is_a?(Prism::StatementsNode) && parent.body.last.equal?(node)
      return false if grandparent.is_a?(Prism::DefNode) &&
                      @public_action_defs.include?(grandparent.object_id)

      grandparent.is_a?(Prism::DefNode) || grandparent.is_a?(Prism::BlockNode) ||
        grandparent.is_a?(Prism::LambdaNode)
    end

    # policy(@x).update?  ->  allowed_to?(:update, @x)
    def classify_policy(node, parent, path, source)
      args = node.arguments&.arguments || []
      unless args.size == 1 && parent.is_a?(Prism::CallNode) && parent.receiver.equal?(node) &&
             parent.name.end_with?("?") && (parent.arguments&.arguments || []).empty?
        @reviews << Review.new(file: path, line: node.location.start_line, kind: "policy",
                               source: slice(parent.is_a?(Prism::CallNode) ? parent : node, source),
                               note: "not a plain policy(x).predicate? chain — rewrite by hand")
        return
      end

      action = parent.name.to_s.delete_suffix("?")
      target = slice(args.first, source)
      @edits << Edit.new(file: path, line: node.location.start_line, kind: "policy_predicate",
                         original: slice(parent, source),
                         replacement: "allowed_to?(:#{action}, #{target})",
                         start_offset: parent.location.start_offset,
                         end_offset: parent.location.end_offset)
      # Pundit convention aliases edit?->update? and new?->create?; the gate
      # enforces edit/new as their OWN keys. The machine report must carry
      # that shift, not just SKILL.md prose.
      if %w[edit new].include?(action)
        @reviews << Review.new(file: path, line: node.location.start_line,
                               kind: "policy_predicate_alias",
                               source: slice(parent, source),
                               note: "rewritten to allowed_to?(:#{action}, ...) — Pundit aliased " \
                                     "#{action}? to #{action == 'edit' ? 'update' : 'create'}?; the gate " \
                                     "enforces #{action} as its own key — check the grid mapping")
      end
    end

    def classify_policy_scope(node, path, source)
      args = node.arguments&.arguments || []
      if args.size == 1 && node.block.nil?
        @edits << Edit.new(file: path, line: node.location.start_line, kind: "policy_scope",
                           original: slice(node, source),
                           replacement: "scope_for(#{slice(args.first, source)})",
                           start_offset: node.location.start_offset,
                           end_offset: node.location.end_offset)
      else
        @reviews << Review.new(file: path, line: node.location.start_line, kind: "policy_scope",
                               source: slice(node, source),
                               note: "unexpected arity/block — rewrite by hand")
      end
    end

    # The statement is the only code on its line(s): safe to remove the line.
    def alone_on_line?(node, source)
      span = full_line_span(node, source)
      outside = source[span[0]...node.location.start_offset].to_s +
                source[node.location.end_offset...span[1]].to_s
      outside.strip.empty?
    end

    def full_line_span(node, source)
      from = (source.rindex("\n", node.location.start_offset) || -1) + 1
      to = source.index("\n", node.location.end_offset)
      [ from, to ? to + 1 : source.length ]
    end

    def slice(node, source)
      source[node.location.start_offset...node.location.end_offset]
    end
  end
end

# --- self-test --------------------------------------------------------------

if ARGV.first == "--self-test"
  require "tmpdir"
  CONTROLLER = <<~RUBY
    class PostsController < ApplicationController
      def index
        @posts = policy_scope(Post).order(:created_at)
      end

      def show
        @post = Post.find(params[:id])
        authorize @post
      end

      def update
        @post = authorize(Post.find(params[:id]))
        head :ok if policy(@post).update?
      end

      def publish
        authorize @post, :publish?
      end

      def attrs
        params.require(:post).permit(permitted_attributes(@post))
      end

      def nested
        head :ok if policy(policy_scope(Post).first).update?
      end

      def guarded
        authorize @post if params[:strict]
      end

      def bare_policy
        policy(@post)
      end

      def edit
        head :ok if policy(@post).edit?
        render :edit
      end

      def cased
        case params[:mode]
        when "strict"
          authorize @post
        end
        head :ok
      end

      def scoped_with_args
        policy_scope(Post, policy_scope_class: CustomScope)
      end

      def lookup_arg
        authorize Post.find(params[:id])
        render :show
      end

      private

      # Private helper: its return value CAN be used by a caller, so a
      # trailing authorize must be reviewed, not deleted.
      def find_and_authorize
        @post = Post.find(params[:id])
        authorize @post
      end
    end
  RUBY

  SKIPPED_CONTROLLER = <<~RUBY
    class WebhooksController < ApplicationController
      skip_before_action :current_scope_check!

      def create
        authorize @event
      end
    end
  RUBY

  STRING_SKIPPED_CONTROLLER = <<~RUBY
    class CallbacksController < ApplicationController
      skip_before_action "current_scope_check!"

      def create
        authorize @callback
      end
    end
  RUBY

  Dir.mktmpdir do |dir|
    file = File.join(dir, "posts_controller.rb")
    File.write(file, CONTROLLER)
    File.write(File.join(dir, "webhooks_controller.rb"), SKIPPED_CONTROLLER)
    File.write(File.join(dir, "callbacks_controller.rb"), STRING_SKIPPED_CONTROLLER)
    File.write(File.join(dir, "show.html.erb"), "<%= link_to 'Edit' if policy(@post).update? %>\n")

    r = CurrentScopeMigrate::CallsiteRewrite.new(dir).scan.report
    failures = []
    expect_kinds = { "policy_scope" => :rewrites, "delete_authorize" => :rewrites,
                     "policy_predicate" => :rewrites, "authorize" => :reviews,
                     "permitted_attributes" => :reviews, "template" => :reviews }
    expect_kinds.each do |kind, bucket|
      failures << "missing #{bucket}:#{kind}" unless r[bucket].any? { |x| x[:kind] == kind }
    end
    # The value-used authorize and the custom-query authorize must be reviews,
    # so exactly ONE authorize is deleted (the statement-position one).
    failures << "expected exactly 1 delete_authorize" unless
      r[:rewrites].count { |x| x[:kind] == "delete_authorize" } == 1
    # posts: value-used, custom-query, modifier-if conditional, case/when
    # conditional, side-effect-arg, last-expression-in-private-helper;
    # webhooks + callbacks: gate-skipped = 8.
    failures << "expected 8 authorize reviews" unless
      r[:reviews].count { |x| x[:kind] == "authorize" } == 8
    failures << "string-form skip must protect its authorize" unless
      r[:reviews].any? { |x| x[:file].end_with?("callbacks_controller.rb") && x[:note].include?("skips current_scope_check!") }
    failures << "case/when authorize must be CONDITIONAL review" unless
      r[:reviews].count { |x| x[:note].include?("CONDITIONAL") } == 2
    failures << "edit? rewrite must carry the alias review" unless
      r[:reviews].any? { |x| x[:kind] == "policy_predicate_alias" && x[:note].include?("edit") }
    failures << "modifier-if authorize must be a review" unless
      r[:reviews].any? { |x| x[:kind] == "authorize" && x[:note].include?("CONDITIONAL") }
    failures << "bare policy(x) must be a review" unless
      r[:reviews].any? { |x| x[:kind] == "policy" }
    failures << "policy_scope with extra args must be a review" unless
      r[:reviews].any? { |x| x[:kind] == "policy_scope" }
    failures << "last-expression authorize must be a review" unless
      r[:reviews].any? { |x| x[:note].include?("last expression") }
    failures << "side-effect-arg authorize must be a review" unless
      r[:reviews].any? { |x| x[:note].include?("side effects") }
    failures << "conditional authorize must carry the conditional note" unless
      r[:reviews].any? { |x| x[:note].include?("CONDITIONAL authorize") }
    # A gate-skipping file must NEVER have its authorize deleted — it may be
    # the only check there.
    failures << "gate-skipped authorize must be a review, never deleted" unless
      r[:reviews].any? { |x| x[:kind] == "authorize" && x[:note].include?("skips current_scope_check!") }

    CurrentScopeMigrate::CallsiteRewrite.rewrite_all!(dir)
    out = File.read(file)
    failures << "policy_scope not rewritten" unless out.include?("@posts = scope_for(Post).order(:created_at)")
    show_body = out[/def show.*?end/m]
    failures << "public-action trailing authorize not deleted" if show_body.nil? || show_body.include?("authorize")
    failures << "private-helper trailing authorize was wrongly deleted" unless
      out[/def find_and_authorize.*?end/m]&.include?("authorize @post")
    failures << "policy predicate not rewritten" unless out.include?("head :ok if allowed_to?(:update, @post)")
    failures << "value-used authorize was wrongly touched" unless out.include?("@post = authorize(Post.find(params[:id]))")
    failures << "custom-query authorize was wrongly touched" unless out.include?("authorize @post, :publish?")
    failures << "nested rewrite incomplete or corrupted" unless
      out.include?("head :ok if allowed_to?(:update, scope_for(Post).first)")
    failures << "file no longer parses after --write" unless Prism.parse(out).success?
    failures << "gate-skipped authorize was deleted" unless
      File.read(File.join(dir, "webhooks_controller.rb")).include?("authorize @event")
    failures << "string-form gate-skipped authorize was deleted" unless
      File.read(File.join(dir, "callbacks_controller.rb")).include?("authorize @callback")
    failures << "case/when authorize was deleted" unless out.include?('when "strict"') &&
                                                         out[/def cased.*?head :ok/m]&.include?("authorize @post")
    failures << "edit? predicate not rewritten" unless out.include?("head :ok if allowed_to?(:edit, @post)")
    failures << "modifier-if authorize was wrongly touched" unless
      out.include?("authorize @post if params[:strict]")
    failures << "arity-mismatched policy_scope was wrongly touched" unless
      out.include?("policy_scope(Post, policy_scope_class: CustomScope)")

    if failures.empty?
      puts "self-test OK (#{r[:counts][:rewrites]} rewrites, #{r[:counts][:reviews]} reviews)"
    else
      failures.each { |f| warn "FAIL #{f}" }
      exit 1
    end
  end
else
  write = ARGV.delete("--write")
  dir = ARGV.first || "app"
  abort "No such directory: #{dir}" unless Dir.exist?(dir)
  if write
    puts JSON.pretty_generate(CurrentScopeMigrate::CallsiteRewrite.rewrite_all!(dir))
  else
    rw = CurrentScopeMigrate::CallsiteRewrite.new(dir).scan
    out = rw.report
    out[:applied] = false
    puts JSON.pretty_generate(out)
  end
end
