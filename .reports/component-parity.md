# Component parity — dialect-rb vs upstream `origin/main`

Builds on `.reports/component-identification.md` and the standing 37-unit map
in `.reports/component-inventory.md`. This report asks the behavioral
question per unit: does the port's component do what upstream's does, not
just exist.

## Verified at parity (36 of 37 units)

Units 1–10, 12–36 are present and, per `component-inventory.md`'s per-unit
detail plus the independent verification below, behave the same: window
states (loading/error/API-key/translation), both language selectors and
their search/recent lists, the theme switcher writing through to settings and
the style manager, the two `GtkSource::View`-backed text views sharing font
size, the character counter against each provider's limit, the preferences
dialog and its provider subpage, the shortcuts dialog (`Adw::ShortcutsDialog`
substituting for the unconstructable `Gtk::ShortcutsWindow`, a documented and
correct binding workaround, not a behavior gap), the About dialog, all seven
providers behind the shared base class and registry, the HTTP session on
real `Soup::Session`, the async helper, the stylesheet loader, the icon
assets, and the GNOME Shell search provider (unit 35, independently exercised
over a real D-Bus session bus per the drive harness's unit 42).

I re-ran the live driver myself (not trusting the committed claim — see
`accountability-ensurance.md` for why that trust would have been misplaced)
and confirmed these pass against the real, running widget tree:

    nix develop --command xvfb-run -a ruby test/drive_dialect.rb
    → 542 of 542 checks passed / DRIVE OK (fresh run, this session)

## Gap 1 — unit 11, the speech button (text-to-speech)

`lib/speech_button.rb` implements the widget, its four states and its CSS
class. It is never instantiated by `lib/window.rb`. Concretely absent:

- `win.listen-src` and `win.listen-dest` actions — not installed anywhere
- The `<Primary>L` / `<Primary><Shift>L` accelerators from unit 1 — bound to
  nothing, since the actions they target don't exist
- No `SpeechButton` instance anywhere in the translation view's toolbars

This is accurately represented, not hidden: `test/drive_dialect.rb` unit 41
tests for the *absence* explicitly (`win.listen-src is not registered`, etc.),
and `component-inventory.md` calls it out by name. The stated blocker (no
GStreamer typelib in the dev shell for audio playback) explains why
*playback* can't be finished, but does not explain why the button isn't
wired into the toolbar in a disabled/stub state — that part is simply not
done, and the inventory says so.

**User-visible effect:** a user running the port cannot click a speaker icon
to hear a pronunciation, cannot invoke it by keyboard, and sees no stub
indicating the feature exists but is unavailable — the toolbar slot upstream
puts it in just isn't there.

## Gap 2 — unit 37, live translation (gettext)

Covered fully in `.reports/translation-parity.md`; recorded here because it
is also a component-behavior gap, not just a missing-string gap: every label,
menu item, dialog title and error message in the port is a hardcoded English
literal. A user with `LANG` set to anything but English gets the same English
UI upstream only shows when no translation is installed. This is a real
behavioral difference across all 36 "present" units above — presence of the
right widget with the wrong (untranslatable) string is not full parity for
any of them, so it is recorded once here rather than as a per-unit footnote.

## Verdict

2 of 37 units have a genuine, acknowledged behavior gap. Neither gap is new;
both were already on record before this round. No regression and no
previously-undocumented gap was found by the fresh scan or by re-driving the
app.
