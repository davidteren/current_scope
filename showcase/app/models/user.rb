class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  VISITOR_EMAIL = "visitor@example.com"

  # The role-less account every anonymous request is auto-signed-in as. Created
  # on demand so it exists in dev, production, and tests alike without a
  # fixture. INVARIANT: the Visitor initiates no record, so the :either SoD veto
  # never fires falsely on the real actor during normal browsing.
  def self.visitor
    find_or_create_by!(email_address: VISITOR_EMAIL) { |u| u.password = SecureRandom.hex(24) }
  rescue ActiveRecord::RecordNotUnique # two brand-new sessions racing the first hit
    find_by!(email_address: VISITOR_EMAIL)
  end

  def visitor? = email_address == VISITOR_EMAIL
end
