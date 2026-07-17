# STI sibling of Invoice. Exists so the suite can hold a grant on one
# Document subclass and gate on the other: the #65 listed-read branch inherits
# scope_for's STI type predicate (sibling denied), while the non-read branch
# keeps its base_class ceiling (sibling allowed) — the pinned read/write split.
class Receipt < Document
end
