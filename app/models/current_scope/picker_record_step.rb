module CurrentScope
  # The scoped-role picker's RECORD step, in one object (#183).
  #
  # The controller builds it; the template reads it. Every display decision —
  # whether a search box is on screen, whether suggesting a search can help,
  # which empty message to render and therefore which id a test selects — is
  # derived here from the same inputs. The template cannot move a control
  # without moving the sentence beside it, which is the drift that produced
  # most of this feature's review findings.
  class PickerRecordStep
    # offered_records is the ONE list the template renders. `records` (the
    # unprepended, role-filtered scan) stays private, or the view has two
    # plausible lists to reach for — the drift this object removes.
    attr_reader :query, :selected

    # records     rows on offer, already role-filtered (nil ⇒ no type chosen)
    # withheld    the role filter removed rows from what was read
    # unread      the scan stopped at its cap: records exist nothing looked at
    # indexed     the type has an indexed search scope, which reads past that cap
    # searchable  the type holds more rows than the search threshold
    # selected    the record on the form — picked from the dropdown or reached
    #             by deep link — that survived the type and role gates
    def initialize(records:, withheld:, unread:, indexed:, searchable:, query:, selected:,
                   locked: false)
      @records = records
      @withheld = withheld
      @unread = unread
      @indexed = indexed
      @searchable = searchable
      @query = query
      @selected = selected
      @locked = locked
    end

    # The empty state is skipped when a deep-linked record survived: it is
    # prepended to the options, and skipping past them would leave a Grant
    # button posting a record the page never shows.
    def show_empty_state?
      offered_records.empty? && query.blank?
    end

    # What the Grant button posts: the record that survived both gates, by its
    # OWN GlobalID. Nil is the button's absence. It is always on the list below,
    # because that list prepends it.
    def grantable_gid
      selected&.to_gid&.to_s
    end

    # The records on offer, the selected one first — the ONE list the select
    # renders, so the button can never post a record the select did not show
    # (#183).
    def offered_records
      list = Array(records)
      return list if selected.nil? || list.any? { |record| same?(record, selected) }

      [ selected, *list ]
    end

    # Records dropped from a list that still HAS records, with no search in
    # effect: the search hint covers the same thing when a query is typed, and
    # without one nothing else on the page mentions them. Silently shortening a
    # list is the surprise this feature exists to remove. offered_records rather
    # than records, or the most shortened list of all — every scanned row
    # refused, one linked record left — would say nothing.
    def shortened?
      @withheld && offered_records.present? && query.blank?
    end

    # Both :shown states mean the list HAS matches — the difference is only
    # whether the role filter took some out of it.
    def matches_shown?
      [ :search_shown, :search_shown_withheld ].include?(search_state)
    end

    # A query that is IN EFFECT always brings its field, whether or not the type
    # is big enough to offer one: the rows on screen were filtered by that term,
    # and hiding the box would leave no way to clear it (#183).
    def offer_search?
      return true if query.present?
      # Nothing over a locked type can take a role, so a search here reaches
      # nothing — and the box would sit directly above the sentence saying so.
      # Only where that sentence actually renders, though: with no role picked
      # the list is unfiltered and the lockdown is not on screen, and hiding the
      # box there would shorten the dropdown with no word about why
      # (#183).
      return false if @locked && show_empty_state?
      return false unless @searchable

      # An empty list only earns a search box where searching can reach past
      # what was read. On a table read to the end there is nothing left to
      # find, and the box would sit beside a message saying so (#183).
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
    # defined once, so no name can carry two sentences (#183).
    #
    # :records_locked             — the type itself accepts no role at all
    # :records_refused_searchable — all read refuse the role, more rows unread,
    #                               and a search can reach them
    # :records_refused_unread     — all read refuse it, more rows unread, and
    #                               no search here can reach them
    # :records_refused            — all read refuse it, nothing left to read
    # :records_none               — the type simply has no records
    def records_state
      # LOCKED first, and on @locked alone: the type declares an empty list and
      # no subclass states one of its own, so no search reaches a record that
      # accepts anything, and neither a role nor a refused row is needed to know
      # it. An empty table refuses nothing, and "no records to pick from yet"
      # would send the operator off to create one on a type that takes no role.
      return :records_locked if @locked
      return :records_refused_searchable if advise_search?
      # The scan stopped at its cap and no indexed scope can read past it, so a
      # grantable record may exist that this page cannot reach. Saying only
      # "pick a different role" would send the operator away from records that
      # do accept the role they picked (#183).
      return :records_refused_unread if @withheld && @unread
      return :records_refused if @withheld

      :records_none
    end

    # The search hint. nil ⇒ no hint at all, because no search is on screen.
    # A surviving record silences the refusals: it is selected and
    # grantable, so "pick a different role" would contradict what is on screen.
    def search_state
      return nil if query.blank?
      # Matches ARE shown, but the role filter took some of them out of the
      # list, and no other hint on the page covers records (#183).
      return @withheld ? :search_shown_withheld : :search_shown if records.present?
      # The query path reaches here with the empty state suppressed, so the
      # lockdown has to be said again: every refusal sentence below would tell
      # the operator to pick a different role, and on a lockdown none helps
      # (#183).
      return :search_locked if @locked
      # A surviving record is selected and grantable, so the plain refusals
      # cannot be said beside it: "pick a different role" contradicts the role
      # that accepts this one. Both cases still say what the query found.
      return @withheld ? :search_refused_selected : :search_none_selected if selected
      return :search_none unless @withheld

      advise_search? ? :search_refused_searchable : :search_refused
    end

    private

    attr_reader :records

    def same?(one, other)
      one.to_gid.to_s == other.to_gid.to_s
    end
  end
end
