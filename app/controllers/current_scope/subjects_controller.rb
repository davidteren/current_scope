module CurrentScope
  class SubjectsController < ApplicationController
    PER_PAGE = 50

    # Identity columns searched by ?q=, in the same preference order as
    # current_scope_subject_label's default chain. Intersected with the subject
    # table's real column_names before use, so a query never spans a page.
    SEARCH_COLUMNS = %w[email email_address name first_name last_name].freeze

    def index
      @query = params[:q].to_s.strip
      scope = filter_subjects(subject_class.order(:id), @query)

      @page = [ params[:page].to_i, 1 ].max
      @subjects = scope.limit(PER_PAGE).offset((@page - 1) * PER_PAGE)
      @has_next_page = scope.offset(@page * PER_PAGE).exists?

      @roles = Role.order(:name)
      # Match on the ids as strings: `where(subject: @subjects)` would build
      # `subject_id IN (SELECT id ...)`, comparing a varchar column to a bigint
      # subquery, which PostgreSQL refuses (#151).
      # Group by each subject's OWN polymorphic_name, not the configured class's:
      # an STI subclass that overrides it stores grants under a different token, so
      # a single where(subject_type:) would omit them (#151). One type in the
      # common case; the per-type OR keeps the STI case correct for one extra WHERE.
      subject_ids_by_type = @subjects.group_by { |subject| subject.class.polymorphic_name }
                                     .transform_values { |subjects| subjects.map { |subject| subject.id.to_s } }
      assignment_scope = subject_ids_by_type.reduce(RoleAssignment.none) do |relation, (type, ids)|
        relation.or(RoleAssignment.where(subject_type: type, subject_id: ids))
      end
      @assignments = assignment_scope
                                   .index_by { |a| [ a.subject_type, a.subject_id.to_s ] }
      # Safe polymorphic resource preload (resolvable types only) — full
      # includes(:resource) NameErrors on a stale resource_type and 500s the
      # page; skip-unresolvable + label as inert instead (#90 / PR #104).
      scoped_scope = subject_ids_by_type.reduce(ScopedRoleAssignment.none) do |relation, (type, ids)|
        relation.or(ScopedRoleAssignment.where(subject_type: type, subject_id: ids))
      end
      scoped_rows = scoped_scope.includes(:role).to_a
      ScopedRoleAssignment.preload_resolvable_resources!(scoped_rows)
      # to_s to match the view's key: subject_id is a string column (#151).
      @scoped = scoped_rows.group_by { |a| [ a.subject_type, a.subject_id.to_s ] }
    end

    private

    # Server-side search across the subject's human-identity columns, so a query
    # matches EVERY subject rather than only the current page's client-side
    # filter. Columns come from the table's real column_names (never interpolate
    # user input as a column name), so this is injection-safe. A Proc
    # subject_label can't be expressed in SQL; when the model exposes none of the
    # searchable columns this returns the scope unfiltered and the per-page
    # client filter remains the only narrowing.
    def filter_subjects(scope, query)
      return scope if query.blank?

      columns = subject_search_columns(scope.klass)
      return scope if columns.empty?

      conn    = scope.klass.connection
      clause  = columns.map { |c| "LOWER(#{conn.quote_column_name(c)}) LIKE ?" }.join(" OR ")
      # ponytail: % / _ in the query pass through as LIKE wildcards — fine for an
      # admin search; add ESCAPE handling if that ever surprises someone.
      scope.where(clause, *([ "%#{query.downcase}%" ] * columns.size))
    end

    def subject_search_columns(klass)
      configured = CurrentScope.config.subject_label
      candidates = []
      candidates << configured.to_s if configured.is_a?(Symbol)
      candidates.concat(SEARCH_COLUMNS)
      candidates.uniq.select { |c| klass.column_names.include?(c) }
    end
  end
end
