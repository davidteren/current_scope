# STI subclass. Invoice.base_class == Document, so Invoice.name != base_class.name
# — the exact case A7 (scope_for STI normalization) exercises.
class Invoice < Document
end
