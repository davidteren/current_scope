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
    attr_reader :records, :query, :role, :deep_linked, :refused

    # records     rows on offer, already role-filtered (nil ⇒ no type chosen)
    # withheld    the role filter removed rows from what was read
    # unread      the scan stopped at its cap: records exist nothing looked at
    # indexed     the type has an indexed search scope, which reads past that cap
    # searchable  the type holds more rows than the search threshold
    # deep_linked a linked record that survived the type and role gates
    def initialize(records:, withheld:, unread:, indexed:, searchable:, query:, role:, deep_linked:,
                   refused: nil, locked: false)
      @records = records
      @withheld = withheld
      @unread = unread
      @indexed = indexed
      @searchable = searchable
      @query = query
      @role = role
      @deep_linked = deep_linked
      @refused = refused
      @locked = locked
    end

    # The empty state is skipped when a deep-linked record survived: it is
    # prepended to the options, and skipping past them would leave a Grant
    # button posting a record the page never shows.
    def empty?
      offered_records.empty? && query.blank?
    end

    # The records on offer, the deep-linked one first — the ONE list the select
    # renders and the Grant button is checked against, so the button can never
    # post a record the select did not show (#183 review).
    # What the Grant button posts: the record that survived both gates, by its
    # OWN GlobalID. Nil is the button's absence.
    def grantable_gid
      deep_linked&.to_gid&.to_s
    end

    def offered_records
      list = Array(records)
      return list if deep_linked.nil? || list.any? { |record| same?(record, deep_linked) }

      [ deep_linked, *list ]
    end

    # Records dropped from a list that still HAS records, with no search in
    # effect — the search hint covers the same thing when a query is typed, and
    # without one nothing else on the page mentions them. Silently shortening a
    # list is the surprise this feature exists to remove (#183 review).
    # offered_records, not records: with every scanned row refused and only the
    # deep-linked one left, the list is at its most shortened and was the one
    # case that said nothing (#183 review).
    def shortened?
      @withheld && role.present? && offered_records.present? && query.blank?
    end

    # Both :shown states mean the list HAS matches — the difference is only
    # whether the role filter took some out of it.
    def matches_shown?
      [ :search_shown, :search_shown_withheld ].include?(search_state)
    end

    # The chosen type declares an empty list: no role will list a record that
    # inherits that declaration, which is what makes "pick a different role"
    # the wrong advice beside it.
    def locked?
      @locked
    end

    # A query that is IN EFFECT always brings its field, whether or not the type
    # is big enough to offer one: the rows on screen were filtered by that term,
    # and hiding the box would leave no way to clear it (#183 review).
    def offer_search?
      return true if query.present?
      return false unless @searchable

      # An empty list only earns a search box where searching can reach past
      # what was read. On a table read to the end there is nothing left to
      # find, and the box would sit beside a message saying so (#183 review).
      records.present? || (@indexed && @unread)
    end

    # Searching can only turn up something new when an indexed scope reads past
    # the scanned window AND that scan stopped at its cap. On a table read to
    # the end, "search for one" is advice that provably cannot succeed.
    def advise_search?
      @withheld && offer_search? && @indexed && @unread
    end

    # ONE state machine, split by WHERE it renders: records_state answers for
    # the block that replaces the record select, search_state for the hint under
    # it, and the two are mutually exclusive (this one is read only when the
    # list is empty with no query, that one only with a query). Every name is
    # defined once, so no name can carry two sentences (#183 review).
    #
    # :records_locked             — the type itself accepts no role at all
    # :records_refused_searchable — all read refuse the role, more rows unread
    # :records_refused            — all read refuse it, nothing left to read
    # :records_none               — the type simply has no records
    def records_state
      # advise_search? FIRST: a locked base can still hold subclass records that
      # declare their own roles, and when a search reads past the scanned window
      # it can find them — "none ever will" would be untrue there (#183 review).
      return :records_refused_searchable if advise_search? && role
      # No @withheld here: an empty table refuses nothing, and a lockdown is
      # knowable on the first visit. "No records to pick from yet" would send
      # the operator off to create one, only to be told then (#183 review).
      return :records_locked if @locked && role
      return :records_refused if @withheld && role

      :records_none
    end

    # The search hint. nil ⇒ no hint at all, because no search is on screen.
    # A surviving deep-linked record silences the refusals: it is selected and
    # grantable, so "pick a different role" would contradict what is on screen.
    def search_state
      # query.present? alone: offer_search? answers true for any query, so
      # asking it here would be a condition that cannot decide anything. It
      # decides in advise_search?, where the box's absence matters.
      return nil if query.blank?
      # Matches ARE shown, but the role filter took some of them out of the
      # list, and no other hint on the page covers records (#183 review).
      return @withheld ? :search_shown_withheld : :search_shown if records.present?
      # A surviving deep-linked record is selected and grantable, so the plain
      # refusals cannot be said beside it: "pick a different role" contradicts
      # the role that accepts this one. Both cases still have something true to
      # say — what the query found, and that the record on screen is the linked
      # one rather than a match (#183 review).
      return @withheld ? :search_refused_linked : :search_none_linked if deep_linked
      return :search_none unless @withheld

      advise_search? ? :search_refused_searchable : :search_refused
    end

    private

    def same?(one, other)
      one.to_gid.to_s == other.to_gid.to_s
    end
  end
end
