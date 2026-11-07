# Component identification — dialect-rb vs upstream `origin/main`

Method: `component-scan.sh` run against a clean checkout of `origin/main`
(`git archive`) and against `lib/` on `ruby`, cross-checked by hand against
the Python/blueprint source and the standing `.reports/component-inventory.md`
(37-unit map). This round re-runs the scan after `c3fcdf9` ("Wire the
already-ported SpeechButton into the window toolbars"), the most recent
commit to touch widget code, to see whether it changes anything on record.

## Scan totals

| | rows |
|---|---:|
| upstream (`/tmp/upstream_dialect/dialect`) | 265 |
| port (`lib/`) | 171 (was 170 before `c3fcdf9` — the one new row is `speech_button.rb css speech-button 1`, now reachable because the button is finally instantiated) |

## What `c3fcdf9` actually changed, read against upstream's `window.py`

Upstream (`window.py:179-200`) **always** registers `listen-src` and
`listen-dest` as `Gio.SimpleAction`s, starts them `enabled = False`, and only
flips them on when a loaded provider actually supports TTS
(`window.py:674-684`). The actions exist in every build, GStreamer or not —
only *enabling* them depends on a TTS-capable provider, not creating them.

The port's commit message gives "no Gst typelib in the dev shell" as the
reason no `listen-src`/`listen-dest` action exists at all. That justifies not
wiring *playback*; it does not justify the actions being entirely absent,
because upstream's own disabled-by-default action needs no GStreamer to
exist — `grep -n listen lib/window.rb lib/main.rb` still shows zero
`add_action`/`install_action` calls for either name, same as before the
commit. The widget is now built into both toolbars and starts hidden
(mirroring upstream's own `load_tts` fallback), which is real progress on
unit 11 from "not instantiated at all" — but "widget present, both actions
and both accelerators (`<Primary>L` / `<Primary><Shift>L`) still absent" is
not the same claim as "wired in."

## A second, upstream-shaped component this round's scan turns up: the Text-to-Speech shortcuts group

`dialect/shortcuts.blp` has **four** `ShortcutsGroup`s: Translator,
**Text-to-Speech**, Navigation, General. The Text-to-Speech group holds two
`ShortcutsShortcut`s, `win.listen-src` and `win.listen-dest`
(`shortcuts.blp:60-71`). `lib/shortcuts_window.rb`'s `SECTIONS` constant has
exactly three top-level keys — Translator, Navigation, General — and no
Text-to-Speech group anywhere. This is a plain, countable component gap: one
whole `ShortcutsGroup` (title + 2 `ShortcutsShortcut`s) that upstream ships
and the port does not, and it was not on record in the previous round's
inventory as its own line item (the previous report folded it into "no
listen-src/listen-dest actions" without naming the shortcuts-window group
specifically). See `component-parity.md` and `accountability-ensurance.md`
for why the port's own driver reports this as "upstream's three groups."

## Scanner false negatives, verified by reading the source (unchanged from the prior round)

`comm -23` between the two symbol sets reports `win.back`, `win.forward`,
`win.clear`, `win.copy`, `win.font-size-inc`, `win.font-size-dec` as present
upstream and absent from the port. Reading `lib/window.rb` shows all six are
implemented via memoized `action_button('win.xxx', ...)` accessors and a
`case`-based dispatch table, not literal `install_action` calls — exactly the
"actions whose name is never a literal" trap the component-identification
skill names. Not a gap.

## Translation-adjacent component: po/ submodule

`po/` is a checked-out git submodule (`dialect-app/po`), `po/ui/dialect.pot`
with 123 `msgid`s. It is wired into nothing — see `translation-parity.md`.

## Conclusion

Beyond the two items already on record (speech button wiring, gettext), this
round's fresh scan surfaces one component the previous identification pass
under-specified: the missing **Text-to-Speech `ShortcutsGroup`** as its own
countable unit, not just a consequence of the missing actions. No other new
missing widget, signal, CSS class or action was found.
