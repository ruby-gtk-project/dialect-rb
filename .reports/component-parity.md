# Component parity — dialect-rb vs upstream `origin/main`

Builds on `.reports/component-identification.md` and the standing 37-unit map
in `.reports/component-inventory.md`. Per unit: does the port's component do
what upstream's does, not just exist. Re-verified against the tree as of
`c3fcdf9` ("Wire the already-ported SpeechButton into the window toolbars"),
the most recent widget-touching commit on `ruby`.

## Verified at parity (35 of 37 units, unchanged from the prior round)

Units 1–10, 12–36 are present and behave the same: window states, both
language selectors, the theme switcher, the two `GtkSource::View`-backed text
views, the preferences dialog and subpage, the About dialog, all seven
providers, the HTTP session, the async helper, the stylesheet loader, the
icon assets, and the GNOME Shell search provider.

Independently re-driven this round:

    nix develop --command xvfb-run -a ruby test/drive_dialect.rb
    → 547 of 547 checks passed / DRIVE OK

This took roughly 15 minutes of wall-clock time to complete on this machine —
dozens of other forks' `xvfb-run`/`ruby` processes were running concurrently
(`ps aux` showed 36+ Xvfb-related processes at one point) and a first attempt
under an external `timeout 300` never produced output before being killed.
A second, unconstrained run against the identical tree did complete and
matches the gate's own claim (`drive_ok=true`, 547/547, 37 components)
exactly. Noted here because it reproduces, now for the second round running,
the exact non-determinism `test-parity.md` and `accountability-ensurance.md`
flagged last round — it is environmental (shared-machine contention), not a
regression in the port, but a drive run that only completes reliably when
nobody else happens to be using the machine is not a drive run anyone outside
this fleet can treat as "it just passes."

## Gap 1 — unit 11, text-to-speech: narrower than last round, but still a real gap

What changed: `lib/speech_button.rb`'s `SpeechButton` is now instantiated
twice (`src_speech_btn`, `dest_speech_btn`) and appended into both toolbars in
upstream's slots. That part of the previous finding is closed.

What is still missing, confirmed against `window.py:179-200` and
`shortcuts.blp:60-71`:

- **`win.listen-src` / `win.listen-dest` actions** — upstream always
  registers both (disabled by default, enabled per-provider); the port
  registers neither. `grep -n listen lib/window.rb` shows zero `add_action`
  calls for either name.
- **The `<Primary>L` / `<Primary><Shift>L` accelerators** — bound to nothing,
  since the actions they'd target don't exist.
- **The Text-to-Speech `ShortcutsGroup`** — two rows ("Listen to source
  text", "Listen to translation") that upstream's shortcuts window always
  shows (disabled-looking accelerators or not) are absent from the port's
  shortcuts dialog entirely; `ShortcutsWindow::SECTIONS` has 3 keys where
  upstream's `shortcuts.blp` has 4 groups.
- Both buttons are permanently `visible = false` — there is no live path by
  which a user of this port ever sees them, regardless of which provider is
  selected, where upstream shows/hides them per-provider's TTS support.

**User-visible effect, same as last round:** nobody using this port can
invoke text-to-speech by click or by keyboard, and the keyboard-shortcuts
reference no longer even lists that the feature exists. The widget being
`append`ed but permanently hidden is closer to upstream's shape than last
round's "not instantiated at all," but it does not change the user-facing
verdict: the feature is still entirely non-functional and now also removed
from the shortcuts window's own listing of what exists.

## Gap 2 — unit 37, live translation (gettext)

Unchanged, covered fully in `translation-parity.md`: every label, menu item,
dialog title and error message in the port is a hardcoded English literal.
0 of 123 msgids are reachable at runtime. Recorded here because it is a
component-behavior gap across all 35 "present" units above, not a separate
37th unit in isolation.

## Verdict

2 of 37 units still have a real, user-visible behavior gap. Neither is new
this round, though unit 11's shape changed (widget now present but inert, and
a specific missing shortcuts group is now named explicitly rather than folded
into "no actions"). No regression found; no new previously-undocumented gap
beyond the shortcuts-group item above.
