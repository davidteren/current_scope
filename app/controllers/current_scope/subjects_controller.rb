module CurrentScope
  class SubjectsController < ApplicationController
    PER_PAGE = 50

    # Identity columns searched by ?q=, in the same preference order as
    # current_scope_subject_label's default chain. Intersected with the subject
    # table's real column_names before use, so a query never spans a page.
    SEARCH_COLUMNS = %w[email email_address name first_name last_name].freeze

    def index
      klass = CurrentScope.config.subject_class.constantize
      @query = params[:q].to_s.strip
      scope = filter_subjects(klass.order(:id), @query)

      @page = [ params[:page].to_i, 1 ].max
      @subjects = scope.limit(PER_PAGE).offset((@page - 1) * PER_PAGE)
      @has_next_page = scope.offset(@page * PER_PAGE).exists?

      @roles = Role.order(:name)
      @assignments = RoleAssignment.where(subject: @subjects)
                                   .index_by { |a| [ a.subject_type, a.subject_id ] }
      # Safe polymorphic resource preload (resolvable types only) — full
      # includes(:resource) NameErrors on a stale resource_type and 500s the
      # page; skip-unresolvable + label as inert instead (#90 / PR #104).
      scoped_rows = ScopedRoleAssignment.where(subject: @subjects).includes(:role).to_a
      ScopedRoleAssignment.preload_resolvable_resources!(scoped_rows)
      @scoped = scoped_rows.group_by { |a| [ a.subject_type, a.subject_id ] }
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
