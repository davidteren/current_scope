# Be sure to restart your server when you modify this file.

# Define an application-wide content security policy.
# See the Securing Rails Applications Guide for more information:
# https://guides.rubyonrails.org/security.html#content-security-policy-header

# Baseline policy for a public site that serves visitor-authored content. No
# inline event handlers or inline styles (the engine's scoped-role picker ships
# as a served asset under script-src 'self', never an inline handler) is the key
# XSS defense. :https is allowed for scripts/styles/fonts so the showcase's
# Google Fonts and any CDN-served assets keep working; tighten to :self only if
# you drop those.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self, :https
    policy.font_src    :self, :https, :data
    policy.img_src     :self, :https, :data
    policy.object_src  :none
    policy.script_src  :self, :https
    policy.style_src   :self, :https
    # Specify URI for violation reports
    # policy.report_uri "/csp-violation-report-endpoint"
  end

  # Importmap and Turbo emit a couple of inline <script> tags (the importmap
  # JSON + the module-shim loader). A per-request nonce on script-src lets those
  # framework scripts run without opening the door to arbitrary inline scripts:
  # javascript_importmap_tags and csp_meta_tag pick the nonce up automatically.
  # style-src is left nonce-free — there are no inline styles (all moved to CSS
  # classes), so any inline style attribute stays correctly blocked.
  # SecureRandom (not request.session.id, which is empty until the session is
  # written) so the nonce is always present; Rails memoizes it per request, so
  # the header and every noticed tag share the same value.
  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]

  # Report violations without enforcing the policy.
  # config.content_security_policy_report_only = true
end
