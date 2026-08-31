# A MID-LEVEL STI class: SpecialInvoice < Invoice < Document. Invoice is neither
# the root nor a leaf, so the picker cannot decide it "answers for itself" — its
# table still holds rows that load as this class, with this class's own
# declaration (#183).
class SpecialInvoice < Invoice
end
