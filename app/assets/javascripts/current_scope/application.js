// The engine's only JavaScript, and pure progressive enhancement.
//
// CSP-safe by construction: it ships as a served asset under script-src 'self'
// (never an inline onchange= handler, which a baseline CSP blocks). One
// delegated change listener auto-submits the scoped-role cascade form when a
// marked control changes — pick a resource type, or type a search — so the next
// step renders without a manual click. Every such control still has a visible
// submit button, so the cascade works with this script disabled, and with no
// Turbo at all (the submit is a plain full-page GET).
document.addEventListener("change", function (event) {
  var el = event.target;
  if (!el || typeof el.matches !== "function") return;
  if (!el.matches("[data-current-scope-autosubmit]")) return;

  var form = el.form || el.closest("form");
  if (form) form.requestSubmit();
});
