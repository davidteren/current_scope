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

// Permission grid: a per-row "enable all" master checkbox toggles every action in its
// controller row, and stays in sync (checked / indeterminate / unchecked) as individual
// actions change. Progressive enhancement — with JS off, each action checkbox still works.
(function () {
  // Matches both channels: raw action checkboxes (role[permission_keys][]) and
  // grouped CRUD checkboxes (role[permission_groups][]).
  var ACTION = 'input[type="checkbox"][name^="role[permission"]';

  function actionsIn(row) { return row.querySelectorAll(ACTION); }

  function syncMaster(row) {
    var master = row.querySelector("[data-cs-row-all]");
    if (!master) return;
    var boxes = actionsIn(row), checked = 0;
    boxes.forEach(function (b) { if (b.checked) checked++; });
    master.checked = boxes.length > 0 && checked === boxes.length;
    master.indeterminate = checked > 0 && checked < boxes.length;
  }

  document.addEventListener("change", function (event) {
    var el = event.target;
    if (!el || typeof el.matches !== "function") return;

    if (el.matches("[data-cs-row-all]")) {
      var row = el.closest("tr");
      if (row) actionsIn(row).forEach(function (b) { b.checked = el.checked; });
      return;
    }
    if (el.matches(ACTION)) {
      var r = el.closest("tr");
      if (r) syncMaster(r);
    }
  });

  document.addEventListener("DOMContentLoaded", function () {
    document.querySelectorAll("[data-cs-row-all]").forEach(function (master) {
      var row = master.closest("tr");
      if (row) syncMaster(row);
    });
    // A grouped CRUD checkbox that's checked but only partially granted
    // (e.g. read = index but not show) reads as indeterminate.
    document.querySelectorAll('[data-cs-partial="true"]').forEach(function (cb) {
      cb.indeterminate = true;
    });
  });
})();

// Subjects page: client-side filter, multi-select, and a bulk "grant scoped role
// to selected" action. Framework-free (no Stimulus dependency) so it works in
// any host; pure progressive enhancement — single-subject assignment still works
// with JS off via each row's "+ scoped role" link.
(function () {
  function rows() {
    var list = document.querySelector("[data-cs-filter-list]");
    return list ? Array.prototype.slice.call(list.querySelectorAll("[data-cs-row]")) : [];
  }
  function visibleRows() { return rows().filter(function (r) { return !r.hidden; }); }
  function selectOf(row) { return row.querySelector("[data-cs-select]"); }
  function selectedRows() {
    return visibleRows().filter(function (r) { var cb = selectOf(r); return cb && cb.checked; });
  }

  function syncBulk() {
    var bar = document.querySelector("[data-cs-bulk]");
    if (bar) {
      var n = selectedRows().length;
      bar.hidden = n === 0;
      var count = bar.querySelector("[data-cs-bulk-count]");
      if (count) count.textContent = String(n);
    }
    var all = document.querySelector("[data-cs-select-all]");
    if (all) {
      var vis = visibleRows();
      var checked = vis.filter(function (r) { var cb = selectOf(r); return cb && cb.checked; });
      all.checked = vis.length > 0 && checked.length === vis.length;
      all.indeterminate = checked.length > 0 && checked.length < vis.length;
    }
  }

  document.addEventListener("input", function (event) {
    if (!event.target.matches || !event.target.matches("[data-cs-filter]")) return;
    var needle = event.target.value.trim().toLowerCase();
    var anyVisible = false;
    rows().forEach(function (row) {
      var match = !needle || row.textContent.toLowerCase().indexOf(needle) !== -1;
      row.hidden = !match;
      if (match) anyVisible = true;
    });
    var empty = document.querySelector("[data-cs-filter-empty]");
    if (empty) empty.hidden = anyVisible || rows().length === 0;
    syncBulk();
  });

  document.addEventListener("change", function (event) {
    if (event.target.matches && event.target.matches("[data-cs-select-all]")) {
      visibleRows().forEach(function (r) { var cb = selectOf(r); if (cb) cb.checked = event.target.checked; });
      syncBulk();
    } else if (event.target.matches && event.target.matches("[data-cs-select]")) {
      syncBulk();
    }
  });

  document.addEventListener("click", function (event) {
    if (event.target.closest && event.target.closest("[data-cs-bulk-clear]")) {
      rows().forEach(function (r) { var cb = selectOf(r); if (cb) cb.checked = false; });
      syncBulk();
      return;
    }
    var go = event.target.closest && event.target.closest("[data-cs-bulk-scoped]");
    if (!go) return;
    event.preventDefault();
    var gids = selectedRows().map(function (r) { return selectOf(r).value; });
    if (!gids.length) return;
    var base = go.getAttribute("data-cs-bulk-url");
    var query = gids.map(function (g) { return "subject_gids[]=" + encodeURIComponent(g); }).join("&");
    window.location = base + (base.indexOf("?") === -1 ? "?" : "&") + query;
  });
})();
