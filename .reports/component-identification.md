# Component identification — dialect-rb vs upstream `origin/main`

Method: `component-scan.sh` against a clean checkout of `origin/main`
(`d237666`) and against `lib/` on `ruby` (`fc10569`), cross-checked by hand
against the Python/blueprint source and the standing
`.reports/component-inventory.md` (37-unit map). This round re-verifies the
scan after the three commits that landed since the last audit
(`c3fcdf9`, `bc3e087`, `fc10569`) — the TTS wiring work — to see whether the
gap that identification flagged last round has actually closed, not just
moved.

## Scan totals

| | rows |
|---|---:|
| upstream (`origin/main`, `dialect/`) | 265 |
| port (`lib/`) | 174 (was 171 at `c3fcdf9`; `bc3e087` adds the `win.listen-src`/`win.listen-dest` actions and the Text-to-Speech `ShortcutsGroup` row) |

## Unit 11 (text-to-speech): the gap identified last round is closed in code

Last round's report (`c3fcdf9`-era) found three concrete absences against
`window.py:179-200` and `shortcuts.blp:60-71`: no `listen-src`/`listen-dest`
actions, no accelerators, no Text-to-Speech `ShortcutsGroup`. Re-reading the
tree at `fc10569`:

- **Actions**: `lib/window.rb`'s `ACTIONS` hash now lists `'listen-dest' =>
  false` and `'listen-src' => false` (disabled by default, matching
  upstream's `enabled = False` at registration), dispatched through
  `on_src_listen_action`/`on_dest_listen_action` in the `case` block
  (`lib/window.rb:1030,1034`). `grep -n listen lib/window.rb` now returns 10
  hits across registration, dispatch, enabling logic and the two
  `SpeechButton#action_name` assignments — not zero.
- **Accelerators**: `lib/main.rb:69-70` binds `'win.listen-dest' =>
  ['<Primary>L']` and `'win.listen-src' => ['<Primary><Shift>L']`, matching
  `main.py`'s own bindings.
- **Shortcuts group**: `lib/shortcuts_window.rb`'s `SECTIONS` now has four
  top-level keys (Translator, **Text-to-Speech**, Navigation, General), with
  the Text-to-Speech group holding exactly upstream's two rows ("Listen to
  source text" → `win.listen-src`, "Listen to translation" →
  `win.listen-dest`), matching `shortcuts.blp:60-71` byte-for-byte on the
  English label text.
- **Enablement**: `#load_tts` and `#check_speech_enabled` (`lib/window.rb`)
  port `window.py`'s `load_tts`/`_check_speech_enabled` — the action is
  enabled only when the active provider's `tts_languages` cover the current
  selection and there is text to speak, same condition upstream uses.

What is still, correctly, not there: actual audio playback. `#on_listen_action`
takes the same early exit upstream's own handler takes when
`Gst.ElementFactory.make` returns `nil` — this dev shell has no Gst typelib,
so `#player` is permanently `nil` on both sides of that comparison. This is
an environment limitation, not a port gap, and it is the one piece of unit 11
this round's drive run still cannot exercise end-to-end (see
`test-parity.md`).

**Verdict: unit 11's identification gap from last round is closed.** The
previous round's most serious structural finding (a check asserting "upstream
has three groups" when it has four) is gone along with the gap it was
covering up — the check now says four and four is correct.

## Scanner false negatives, verified by reading the source (unchanged)

`comm -23` between the two symbol sets still reports `win.back`, `win.forward`,
`win.clear`, `win.copy`, `win.font-size-inc`, `win.font-size-dec` as present
upstream and absent from the port's scan. Reading `lib/window.rb` shows all
six are implemented via memoized `action_button('win.xxx', ...)` accessors
and dispatched through the same `case` table as everything else — not
literal `install_action` calls, exactly the "actions whose name is never a
literal" trap this skill names. Not a gap.

## Translation-adjacent component: po/ submodule — unchanged

`po/` is a checked-out git submodule (`dialect-app/po`), `po/ui/dialect.pot`
with 123 `msgid`s, plus a second CLDR-language catalog. Checked out in the
tree, wired into nothing at runtime — see `translation-parity.md`.

## A component the identification pass had not separately named before: the HTTP session's threading model

Reading `lib/session.rb`'s own header comment (flagged by the
accountability grep, see `accountability-ensurance.md`) surfaces a
component-level behavioral fact worth recording here rather than only there:
upstream's `Session`/`soup.py` issues requests from asyncio coroutines that
suspend the GLib main loop cooperatively; the port's `Session` calls soup3's
synchronous `#send_and_read` from a worker thread (`BackgroundTask`), and
that call does not release Ruby's GVL for its duration (confirmed in the
comment against a same-process loopback server on a second thread, which
never got scheduled). This is not a widget, so it carries no CSS/signal/
action rows of its own, but it is a real difference in a component's
*behavior under load* that the widget-level scan cannot see and that no
check in `test/drive_dialect.rb` exercises, because the drive harness's own
provider answers from memory with no real I/O. See `component-parity.md` and
`accountability-ensurance.md`.

## Conclusion

The one open item this skill's prior pass carried — unit 11's three missing
pieces (actions, accelerators, shortcuts group) — is closed in the current
tree. The translation gap (unit 37) is unchanged and total. One
previously-undocumented behavioral fact (the session's blocking I/O inside a
background thread) is named here for the first time, carried through to
`component-parity.md` as a new, disclosed finding rather than a counted
widget gap.
