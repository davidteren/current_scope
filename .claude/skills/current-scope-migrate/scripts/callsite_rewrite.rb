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

    def initialize(dir)
      @dir = dir
      @edits = []
      @reviews = []
    end

    attr_reader :edits, :reviews

    def scan
      Dir.glob(File.join(@dir, "**", "*.rb")).sort.each { |f| scan_ruby(f) }
      Dir.glob(File.join(@dir, "**", "*.erb")).sort.each { |f| scan_erb(f) }
      self
    end

    def apply!
      edits.group_by(&:file).each do |file, file_edits|
        source = File.read(file)
        # Bottom-up so earlier offsets stay valid.
        file_edits.sort_by(&:start_offset).reverse_each do |e|
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
      walk(parse.value, nil, path, parse.source.source)
    end

    # ERB cannot be parsed as Ruby here — report occurrences, never rewrite.
    def scan_erb(path)
      File.foreach(path).with_index(1) do |text, lineno|
        next unless text =~ /\b(policy_scope|policy|authorize|permitted_attributes)\b/

        @reviews << Review.new(file: path, line: lineno, kind: "erb", source: text.strip,
                               note: "ERB template — rewrite by hand " \
                                     "(policy(x).foo? -> allowed_to?(:foo, x); policy_scope(X) -> scope_for(X))")
      end
    end

    def walk(node, parent, path, source)
      classify(node, parent, path, source) if node.is_a?(Prism::CallNode)
      node.child_nodes.compact.each { |c| walk(c, node, path, source) }
    end

    def classify(node, parent, path, source)
      return unless node.receiver.nil?

      case node.name
      when :authorize then classify_authorize(node, parent, path, source)
      when :policy then classify_policy(node, parent, path, source)
      when :policy_scope then classify_policy_scope(node, path, source)
      when :permitted_attributes
        @reviews << Review.new(file: path, line: node.location.start_line,
                               kind: "permitted_attributes", source: slice(node, source),
                               note: "no current_scope equivalent — keep strong params in the controller")
      end
    end

    def classify_authorize(node, parent, path, source)
      args = node.arguments&.arguments || []
      line = node.location.start_line
      if args.size == 1 && node.block.nil? && parent.is_a?(Prism::StatementsNode) &&
         alone_on_line?(node, source)
        del = full_line_span(node, source)
        @edits << Edit.new(file: path, line: line, kind: "delete_authorize",
                           original: slice(node, source), replacement: "",
                           start_offset: del[0], end_offset: del[1])
      else
        note =
          if args.size != 1 then "custom query / extra args — map to the gate key by hand"
          elsif !parent.is_a?(Prism::StatementsNode) then "return value is used — assign the record instead, the Guard gates the action"
          else "shares its line with other code — delete by hand"
          end
        @reviews << Review.new(file: path, line: line, kind: "authorize",
                               source: slice(node, source), note: note)
      end
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
    end
  RUBY

  Dir.mktmpdir do |dir|
    file = File.join(dir, "posts_controller.rb")
    File.write(file, CONTROLLER)
    File.write(File.join(dir, "show.html.erb"), "<%= link_to 'Edit' if policy(@post).update? %>\n")

    rw = CurrentScopeMigrate::CallsiteRewrite.new(dir).scan
    r = rw.report
    failures = []
    expect_kinds = { "policy_scope" => :rewrites, "delete_authorize" => :rewrites,
                     "policy_predicate" => :rewrites, "authorize" => :reviews,
                     "permitted_attributes" => :reviews, "erb" => :reviews }
    expect_kinds.each do |kind, bucket|
      failures << "missing #{bucket}:#{kind}" unless r[bucket].any? { |x| x[:kind] == kind }
    end
    # The value-used authorize and the custom-query authorize must be reviews,
    # so exactly ONE authorize is deleted (the statement-position one).
    failures << "expected exactly 1 delete_authorize" unless
      r[:rewrites].count { |x| x[:kind] == "delete_authorize" } == 1
    failures << "expected 2 authorize reviews" unless
      r[:reviews].count { |x| x[:kind] == "authorize" } == 2

    rw.apply!
    out = File.read(file)
    failures << "policy_scope not rewritten" unless out.include?("@posts = scope_for(Post).order(:created_at)")
    failures << "statement authorize not deleted" if out.match?(/^\s*authorize @post\s*$/)
    failures << "policy predicate not rewritten" unless out.include?("head :ok if allowed_to?(:update, @post)")
    failures << "value-used authorize was wrongly touched" unless out.include?("@post = authorize(Post.find(params[:id]))")
    failures << "custom-query authorize was wrongly touched" unless out.include?("authorize @post, :publish?")
    failures << "file no longer parses after --write" unless Prism.parse(out).success?

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
  rw = CurrentScopeMigrate::CallsiteRewrite.new(dir).scan
  rw.apply! if write
  out = rw.report
  out[:applied] = !write.nil?
  puts JSON.pretty_generate(out)
end
