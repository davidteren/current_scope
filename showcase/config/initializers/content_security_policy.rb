# Be sure to restart your server when you modify this file.

# Define an application-wide content security policy.
# See the Securing Rails Applications Guide for more information:
# https://guides.rubyonrails.org/security.html#content-security-policy-header

# Baseline policy for a public site that serves visitor-authored content: no
# inline scripts (the engine's scoped-role picker ships as a served asset under
# script-src 'self', never an inline handler) is the key XSS defense. :https is
# allowed for scripts/styles/fonts so the showcase's Google Fonts and any
# CDN-served assets keep working; tighten to :self only if you drop those.
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

  # No nonces: the app has no inline scripts/styles that need them, and the
  # engine's picker JS is a served asset. Enable the block below only if you add
  # inline <script>/<style> that must be allow-listed.
  #
  # config.content_security_policy_nonce_generator = ->(request) { request.session.id.to_s }
  # config.content_security_policy_nonce_directives = %w(script-src style-src)
  # config.content_security_policy_nonce_auto = true

  # Report violations without enforcing the policy.
  # config.content_security_policy_report_only = true
end
