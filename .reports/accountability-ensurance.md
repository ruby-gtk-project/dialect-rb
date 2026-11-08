# Accountability ensurance — dialect-rb

Grep for excuse language, per the task's word list:

    grep -rniE "TODO|FIXME|not implemented|for now|in a future" lib exe .reports
    → no new matches in lib/exe (the only hits are this report's own grep
      command and its own prose quoting it)

    find . -iname "PORTING.md" -not -path './.git/*'
    → none exists

    bash .claude/skills/accountability-ensurance/scripts/find-excuses.sh .
    → lib/session.rb:66  "out of scope" — redefines the target so the current state hits it
    → lib/google_provider.rb:17  "no Ruby equivalent" — the analogue is the BEHAVIOUR, which always has one

No hits on the narrow TODO/FIXME word list. The skill's own script flags two
broader phrases; both were read in full, in context, this round.

## The two flagged phrases, read in context

**`lib/google_provider.rb:17`, "There is no Ruby equivalent"**: the comment
explains that upstream gets TTS from Python's `gtts` package, and the port
instead talks directly to the same `/translate_tts` endpoint `gtts` itself
calls, reproducing its chunking and its language table in
`TTS_LANGUAGES`. Read fully, this is not an excuse for missing behavior — the
behavior (speech synthesis via Google's endpoint) is reimplemented, not
skipped. "No Ruby equivalent to a Python *package*" is a true, narrow
statement about tooling, immediately followed by what was built instead of
that package. **Not a finding** — this is a located, working correspondence
per `component-parity`'s own rule that a correspondence is resolved by
naming where the behavior lives, which this comment does.

**`lib/session.rb:66`, "out of scope for this round"**: this one is a real
finding, but not the "excuse without substance" kind the skill is built to
catch. The full comment (quoted in `component-parity.md`) names the exact
mechanism (soup3's synchronous call not releasing the GVL), demonstrates it
with a loopback-server repro, states the concrete user-visible consequence
(the UI can stall for the length of a request), and names precisely what
fixing it would require (driving soup3 asynchronously off the GLib main
loop, touching every provider file and `BackgroundTask`'s contract). That is
the opposite of "for now" as a label with nothing behind it — it is a gap
disclosed with enough detail that another agent could act on it directly.
**The finding is that this gap exists and has zero test coverage** (see
below), not that it was hidden. Recording it as newly-identified in
`component-parity.md` and `component-identification.md` this round, since no
previous round's reports named it.

## Finding 1: a real, previously-unrecorded gap with zero coverage on either side — disclosed, not hidden

`lib/session.rb`'s synchronous-call-blocks-GVL behavior (above) means a real,
slow provider can freeze the whole process, not just a background thread.
`test/drive_dialect.rb` cannot catch this by its own necessary design — its
`DriveProvider` answers from memory with no real I/O, specifically so the
suite does not depend on the internet. So this is a genuine behavior gap
from upstream's asyncio model, named honestly in the source, that has never
been mentioned in any committed report before this round and is covered by
no check on either side. This is exactly the task's standard: a component no
check exercises is unverified, not done — the fact that the code comment
itself is honest about it changes how serious a *disclosure* finding this
is, but not whether the underlying behavior is verified. It is not, and this
round's reports now say so in two places (`component-parity.md`,
`test-parity.md`).

## Finding 2: last round's false-green check is fixed, and fixed correctly

Last round's most serious finding was `test/drive_dialect.rb:976`'s
`d.check("it has upstream's three groups") { ShortcutsWindow::SECTIONS.length
== 3 }` — a passing check whose label asserted something false about
upstream's own shape (four groups, not three), while the port lacked the
fourth. This round's `bc3e087`/`fc10569` built the missing Text-to-Speech
group for real and changed the check to assert `== 4`, with the group's two
rows and action names also asserted
(`ShortcutsWindow::SECTIONS["Text-to-Speech"] == {...}`). Read directly: the
check's label and its assertion now agree with each other and with
upstream's actual `shortcuts.blp`. **This is the correct fix** — not
relabeling a false check to match the port's shape, but building the
missing feature and then making the check assert the real upstream number.
No new instance of this pattern (a check whose label claims more than it
tests) was found elsewhere in this round's reading of `test/drive_dialect.rb`.

## Finding 3: `.reports/drive-harness.md` is current this round — the staleness pattern from the prior two rounds did not recur

Both previous rounds flagged `drive-harness.md` for lagging the code by one
commit's worth of checks (536→542 stale, then 536→547 stale by a larger
margin). This round, the commit that changed the check count
(`fc10569`) also updated `drive-harness.md` in the same commit — confirmed
via `git show --stat fc10569`, which touches both `test/drive_dialect.rb` and
`.reports/drive-harness.md` together. The document's own stated count
(557/557, 45 steps) was independently reproduced this round (see
`test-parity.md`). **The specific failure mode flagged twice before did not
recur.**

## Finding 4: translation gap is still reported honestly, and still large

`component-identification.md`, `component-parity.md` and
`translation-parity.md` all continue to state outright that gettext
integration does not exist and that 0 of 123 msgids are reachable. Unchanged
across three rounds, and unchanged in how honestly it is disclosed.

## Finding 5: the drive suite's step 48 title is accurate but easy to over-read

`d.step("the translation catalogs are checked out")` checks only that `po/`
and `po/cldr-langs/` exist as directories — it does not and cannot check
string reachability, and it does not claim to. The title is literally true.
Flagged here only because a reader skimming green step titles without
`translation-parity.md` open beside them could misread "the translation
catalogs are checked out" as "translations work." Not a false-green finding
on its own terms (the check tests exactly what its name says), but adjacent
enough to last round's Finding 1 pattern that it is worth a line rather than
silence.

## Finding 6: this round, I could not independently corroborate the gate's number at all — a worse outcome than either previous round's

Both previous rounds eventually reproduced the gate's claimed pass count
manually, inside their own time budget (taking on the order of 15 minutes
each under contention). This round's independent re-run had not finished —
not failed, not hung, just still running, having reached step 49 of 50
cleanly per its screenshots — when this report had to be written. See
`test-parity.md` for the detail. I am treating this round's gate number
(`drive_ok=true`, 557/557, 45 components) as asserted by the task, not
verified by this audit, which is a weaker evidentiary position than either
of the previous two rounds reached. This is not evidence the gate is wrong;
my own run's progress is consistent with it. But "the auditor ran out of
time trying to confirm it" is a different, and worse, statement than
"the auditor confirmed it, slowly," and the previous two rounds' reports
should not be read as having established that this harness is reliable
enough to skip re-verifying — if anything, three rounds running of this
exact friction argue the opposite.

## Verdict

Not clean. Last round's most serious finding (a check that misstated
upstream's own shape) is fixed correctly, not papered over, and the
staleness pattern flagged twice before did not recur this round — real
progress. But this round adds two things that keep the project from a clean
bill: a newly-surfaced, zero-coverage behavioral gap (Finding 1, session
blocking I/O), and a weaker evidentiary position on the runtime gate itself
than either previous round reached (Finding 6 — I could not independently
reproduce 557/557 inside this round's budget, where the previous two rounds
did). The translation gap (Finding 4) remains honestly disclosed and
completely unresolved. The rspec gap is carried forward unchanged for a
third round and is itself worth naming again: a suite that has never once
executed successfully, three rounds running, with no mention of that fact
in any commit message, is a quieter version of exactly what this skill
greps for, even though the narrow word list does not catch it.
