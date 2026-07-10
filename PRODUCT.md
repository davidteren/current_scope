# Product

## Register

product

## Platform

web

## Users

Two audiences, one product.

- **Adopting Rails developers** — the people who add the `current_scope` gem,
  run the install generator, and mount the engine. They meet the product first
  as a *mountable engine* (in the lineage of Devise / ActiveAdmin): setup
  scripts analyse the host app's controllers and actions, generators scaffold
  the views, and the engine derives a permission catalog from the routes. Their
  context is a terminal, a Gemfile, and a half-built app; the job to be done is
  "make authorization real without hardcoding rules I'll have to redeploy."
- **Authorization administrators** — the full-access subjects who actually
  operate the mounted management UI at `/current_scope`: editing the role grid,
  granting org-wide and scoped roles, reading who-can-do-what. Their context is
  a security control, often under audit. The job is to change what a role means,
  or grant one person one record, *correctly and legibly*, without touching code.

The **demo app** (`demo/`) is a third, illustrative surface: a full Rails 8.1
host app that validates every mechanism end to end and doubles as the reference
for what a well-dressed host integration looks like. It should read as a real,
decent product in its own right, not a throwaway harness.

## Product Purpose

CurrentScope is **authorization as data you edit in a UI, not rules you
hardcode and redeploy** — with one ambient context that makes `allowed_to?`
resolve identically in controllers, views, and ViewComponents.

Every `controller#action` *is* a permission, derived automatically from the
router. A role is an editable bundle of those permissions (ticked cells on a
controller × action grid), holdable org-wide or scoped to one record. A single
fail-closed resolver answers every check, with a structural
separation-of-duties veto that overrides even full access.

Success is measured on two fronts:

- **For the adopter:** the generated management UI and scaffolded host views
  look and feel considered out of the box — *decent by default*, fully
  restyleable by the host. The gem is not "functional but ugly, override it
  yourself" (the Devise-scaffold reputation); the neutral scaffold is a floor
  worth shipping, and overriding it is an upgrade, not a rescue.
- **For the administrator:** the permission grid, role editor, and
  scoped-grant flows make a genuinely dense security surface *legible* — the
  state of who-may-do-what is never a guess.

## Brand Personality

**Official. Considered. Load-bearing.** Authorization is the business of seals,
signatures, and countersignatures — a decision with consequences, recorded.
The interface should carry that gravity: three words — *ceremonial, exact,
trustworthy*.

The demo app expresses this as "the harbor master's ledger" — official ink
blue on plain paper, brass for what's pending, oxblood for what's denied, and
approval rendered as the thing it is: a stamp. **Keep the spirit, stay open on
the framing.** The durable commitment is the *ceremonial-official* register
(authorization = a countersigned decision), not the nautical metaphor
specifically; future work may re-theme the surface as long as it keeps that
weight. Approval-as-a-stamp and the four-eyes countersign note are the kind of
move that earns its place: it teaches the mechanism by being it.

The gem's own scaffold UI carries the same seriousness in a **host-agnostic,
restrained** key — it cannot assume the host's tokens, so it earns "considered"
through typography, spacing, and clear structure rather than a committed
palette.

## Anti-references

- **Enterprise IAM console.** Not AWS-IAM / Okta grey density — no sprawling,
  joyless, permission-soup enterprise-security-tool look. Density is the enemy
  to design *against*; a permission grid can be dense and still legible.
- **Dark-mode developer tool.** No neon-on-black terminal aesthetic. The ledger
  is ink-on-paper light; the register is officialdom, not hacker-console.
- **Generic SaaS dashboard.** No purple-gradient hero-metric cards, no identical
  icon+heading+text card grids, no template admin panel. This is a record of
  decisions, not a metrics dashboard.

## Design Principles

1. **The interface teaches the mechanism.** Where a control has a real-world
   analogue (a stamp for approval, a countersignature for four-eyes), render it
   as that thing. The UI should make the authorization model self-evident, not
   merely operate it.
2. **Legible under density.** The core surfaces (permission grid, role editor,
   scoped grants) are inherently dense. Fight the enterprise-console reflex:
   structure, whitespace, and typographic hierarchy carry the density — never
   more chrome.
3. **Decent by default, yours by override.** The gem's shipped scaffold is a
   floor worth mounting as-is; the host restyles by supplying its own tokens
   and layout, and that path (see the demo) is a first-class, documented move —
   not a rescue from ugliness.
4. **Fail-closed, shown closed.** The product's spine is default-deny and a
   non-negotiable veto. The UI must never imply an ability the resolver would
   refuse; what you can't do should read as unavailable, not merely hidden.
5. **One source of truth, top to bottom.** Gate, view, and component ask the
   same resolver; the design mirrors that — the same permission state looks the
   same wherever it surfaces, so the view can never contradict the gate.

## Accessibility & Inclusion

Target **WCAG 2.2 AA**.

- Body text ≥ 4.5:1, large/bold text ≥ 3:1, against its actual background —
  including the brass/oxblood/approve washes, not just ink-on-white.
- Visible, non-color focus indication on every interactive control; the
  permission grid and scoped-grant forms are keyboard-operable in a sensible
  focus order (dense, form-heavy surfaces are where keyboard access matters
  most).
- State is never carried by color alone — a stamp reads by its label and shape,
  not hue; denied vs pending vs approved is legible in monochrome.
- `prefers-reduced-motion` is honored (the stamp-in settle already degrades to
  no animation); reduced-motion is an alternative, not a removal.
