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

// Light/dark theme toggle. Progressive enhancement: the server already renders
// the chosen theme from the cs_theme cookie (so there's no flash), and defaults
// to the OS preference when no cookie is set. This just flips the choice live
// and persists it. CSP-safe (served asset, no inline handler).
document.addEventListener("click", function (event) {
  var btn = event.target.closest && event.target.closest("[data-cs-theme-toggle]");
  if (!btn) return;

  var root = document.documentElement;
  var current = root.getAttribute("data-cs-theme");
  var effectiveDark = current
    ? current === "dark"
    : window.matchMedia("(prefers-color-scheme: dark)").matches;
  var next = effectiveDark ? "light" : "dark";

  root.setAttribute("data-cs-theme", next);
  document.cookie = "cs_theme=" + next + ";path=/;max-age=31536000;samesite=lax";
  btn.setAttribute("aria-pressed", String(next === "dark"));
});
