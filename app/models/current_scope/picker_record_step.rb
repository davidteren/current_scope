module CurrentScope
  # The scoped-role picker's RECORD step, in one object (#183 review).
  #
  # The controller builds it; the template reads it. Every display decision —
  # whether a search box is on screen, whether suggesting a search can help,
  # which empty message to render and therefore which id a test selects — is
  # derived here from the same inputs. The template cannot move a control
  # without moving the sentence beside it, which is the drift that produced
  # most of this feature's review findings.
  class PickerRecordStep
    attr_reader :records, :query, :role, :deep_linked

    # records     rows on offer, already role-filtered (nil ⇒ no type chosen)
    # withheld    the role filter removed rows from what was read
    # unread      the scan stopped at its cap: records exist nothing looked at
    # indexed     the type has an indexed search scope, which reads past that cap
    # searchable  the type holds more rows than the search threshold
    # deep_linked a linked record that survived the type and role gates
    def initialize(records:, withheld:, unread:, indexed:, searchable:, query:, role:, deep_linked:)
      @records = records
      @withheld = withheld
      @unread = unread
      @indexed = indexed
      @searchable = searchable
      @query = query
      @role = role
      @deep_linked = deep_linked
    end

    # The empty state is skipped when a deep-linked record survived: it is
    # prepended to the options, and skipping past them would leave a Grant
    # button posting a record the page never shows.
    def empty?
      records.blank? && deep_linked.nil? && query.blank?
    end

    def offer_search?
      @searchable && (records.present? || @indexed || query.present?)
    end

    # Searching can only turn up something new when an indexed scope reads past
    # the scanned window AND that scan stopped at its cap. On a table read to
    # the end, "search for one" is advice that provably cannot succeed.
    def advise_search?
      @withheld && offer_search? && @indexed && @unread
    end

    # :refused_searchable — everything read refuses the role, more rows unread
    # :refused            — everything read refuses the role, nothing left to read
    # :none               — the type simply has no records
    def records_state
      return :refused_searchable if advise_search? && role
      return :refused if @withheld && role

      :none
    end

    # The search hint. nil ⇒ no hint at all, because no search is on screen.
    # A surviving deep-linked record silences the refusals: it is selected and
    # grantable, so "pick a different role" would contradict what is on screen.
    def search_state
      return nil unless offer_search? && query.present?
      return :shown if records.present?
      # Records DID match and the role filter removed them, so "no records
      # match" would be untrue — and the linked record beside the hint is
      # selected and grantable, so "pick a different role" would contradict it.
      # Say nothing rather than either (#183 review).
      return nil if @withheld && deep_linked
      return :none unless @withheld && role

      advise_search? ? :refused_searchable : :refused
    end
  end
end
