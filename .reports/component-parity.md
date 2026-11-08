# Component parity — dialect-rb vs upstream `origin/main`

Builds on `.reports/component-identification.md` and the standing 37-unit map
in `.reports/component-inventory.md`. Per unit: does the port's component do
what upstream's does, not just exist. Re-verified against the tree at
`fc10569` ("Fix accel check comparing against GTK's canonical spelling,
confirm DRIVE OK"), the tip of `ruby` this round, three commits past the
previous audit's `c3fcdf9`.

## Unit 11 (text-to-speech): closed this round

The previous round's open gap — no `listen-src`/`listen-dest` actions, no
accelerators, no Text-to-Speech `ShortcutsGroup` — is closed by `bc3e087` and
confirmed by `fc10569`'s fix to the check that verifies it (see
`accountability-ensurance.md` for why that check needed fixing in its own
right, not just the underlying feature). Read directly against the current
tree:

- `win.listen-src`/`win.listen-dest` are registered, disabled by default,
  dispatched through the window's action table (`lib/window.rb`).
- `<Primary>L` / `<Primary><Shift>L` are bound in `lib/main.rb`, matching
  `main.py`.
- `ShortcutsWindow::SECTIONS` has upstream's four groups, with the
  Text-to-Speech group's two rows matching `shortcuts.blp:60-71`.
- `#load_tts`/`#check_speech_enabled` reproduce `window.py`'s
  `load_tts`/`_check_speech_enabled`: the action is enabled only when the
  active provider's `tts_languages` cover the current selection and there is
  text present.

What remains out of scope, correctly: actual audio playback, because there is
no Gst typelib in this dev shell and `Gst.ElementFactory.make` returning
`nil` is a case upstream's own handler already takes the same early exit on.
Unit 11 now has **behavioral** parity for everything the environment can
exercise; only the one piece neither side of the comparison can run in this
sandbox is left open, and it is open on both sides symmetrically, not just
the port's.

**Verdict: unit 11 is at parity.** This closes the last round's Gap 1.

## Unit 37 (live translation / gettext): unchanged, still open

Covered fully in `translation-parity.md`. 0 of 123 msgids are reachable at
runtime; every label, menu item, dialog title and error message in the port
remains a hardcoded English literal. No commit in this round's range touches
it. **Gap, unchanged.**

## New this round, found while re-reading: a disclosed but real behavioral gap in the HTTP session (not a counted unit, but worth a row)

`lib/session.rb`'s own header comment (surfaced by the accountability grep)
states plainly that the port's `Session` calls soup3's synchronous
`#send_and_read` from inside `BackgroundTask`'s worker thread, and that this
call does not release Ruby's GVL for its duration — confirmed in the comment
against a same-process loopback server on a second thread that never got
scheduled to answer until the request timed out. Upstream's asyncio
coroutines suspend cooperatively and never hold the process this way.
Concretely: **a real translation request in this port can stall the whole
process, including the GTK main loop, for the length of that request** — not
merely the worker thread upstream's coroutine model would have kept it to.

This is disclosed, in detail, in the source itself (not hidden, not an
excuse-word match — see `accountability-ensurance.md`), and it is explicitly
named as "out of scope for this round" by the commit that wrote it. That
makes it an honest gap rather than a false claim. But it is still a real,
user-facing behavioral difference from upstream — a provider that's slow to
respond freezes the UI in the port in a way it does not upstream — and
**nothing in `test/drive_dialect.rb`'s 557 checks can catch it**, because the
drive harness's own `DriveProvider` answers from an in-memory array with no
real I/O at all. This is exactly the task's framing: a component — the
session's behavior under a real, slow network call — that no check
exercises is unverified, not done, regardless of how green the rest of the
suite is. Recorded here as a parity gap in the interaction between units
20–23 (provider framework) and 31 (`Session`), not as a widget-count gap on
either unit's row.

## Verdict

1 of 37 units still has an open, undisclosed-nowhere-else-as-closed gap
(unit 37, translation) — unchanged from last round. Unit 11 (text-to-speech),
the previous round's other open gap, is closed. One new finding this round
is a real behavioral difference (session blocking under real I/O) that is
honestly disclosed in the source but not exercised by any check and not
previously recorded in this ledger — it is added here now. Net: fewer open
component gaps than last round (1 vs. 2), plus one newly-surfaced,
honestly-disclosed-but-unverified behavioral gap.
