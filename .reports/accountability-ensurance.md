# Accountability ensurance — dialect-rb

Grep for excuse language, per the task's word list:

    grep -rniE "TODO|FIXME|not implemented|for now|in a future" lib exe .reports
    → no matches

    find . -iname "PORTING.md" -not -path './.git/*'
    → none exists

No excuse-language hits in `lib/`, `exe/` or `.reports/`, and there is no
`PORTING.md` to check. On that narrow grep, the tree is clean. The real
findings in this round are structural, not textual.

## Finding 1 (most serious): the standing drive-harness report is stale and
## under-counts the project's own last claimed total

`.reports/drive-harness.md` states:

> "Last run (2026-11-07): **536 of 536 checks passed — DRIVE OK**, 42 steps,
> 9 screenshots, confirmed over two consecutive clean runs."

But the most recent commit to touch the drive script, `54b3308` ("Port the
GNOME Shell search provider and check out po/"), says in its own message:

> "updates test/drive_dialect.rb's 'absent' checks for units 35/37 into real
> coverage of the new behaviour (542/542 checks pass)"

`git log --oneline -- .reports/drive-harness.md` shows that file was last
written by the *previous* commit (`e4ffcd9`), and `54b3308` changed the drive
script and raised the passing count to 542 without updating
`.reports/drive-harness.md` to match. A reader of that report today sees
"536 of 536" and a timestamp of today's date, and reasonably concludes that
is still the current, complete count — it is not. This is exactly the
pattern the task asks to be caught: a green claim (536/536, "DRIVE OK") that
no longer matches the code it describes, left in place past the commit that
outdated it. It is not a lie — nothing in it is false as of when it was
written — but it is now a false green by omission, and I am recording it as
a finding rather than silently fixing it in this audit, since fixing it is
this round's job, not mine to do unasked.

## Finding 2: this round's own runtime gate contradicts both of those reports

This round's gate: **drive_ok=false, 0 checks passed, 0 failed**, across 49
components. Both `.reports/drive-harness.md` (536/536) and the `54b3308`
commit message (542/542) assert a fully green, fully executed drive run.
The gate that is supposed to be ground truth for this round says the drive
run produced nothing — not a partial failure, zero of everything, which
reads as "never completed" rather than "ran and found problems."

I reproduced something consistent with that failure mode directly: running
`test/drive_dialect.rb` under an external 180-second timeout, the process
was still alive, still doing nothing, 195 seconds in — it never printed a
single line of output before I gave up on that attempt. A second,
unconstrained run of the identical command against the identical tree
completed in well under that window and passed 542/542. Full detail and the
(unresolved) question of what's different about the gate's own invocation is
in `.reports/test-parity.md`.

**The accountability point:** neither number — 536, 542, nor "542/542,
confirmed by me just now" — should be read as "the drive suite is reliably
green." A suite that sometimes hangs indefinitely under the exact conditions
this round's gate ran it in is not a suite anyone can treat as passing on
the strength of one person's one clean manual run, including mine. Per the
task's own framing: a component no check exercises is unverified, not done,
and right now, by the gate's own account, *no* check ran this round.

## Finding 3: the rspec suite's green is as false as it gets — it cannot
## even load

`spec/` has zero spec files and a `spec_helper.rb` that fails to require its
own stated harness gem (`kettle/test/rspec`) under the project's own dev
shell. `spec/README.md` documents a rich set of helpers (`stub_env`,
`block_is_expected`, `pending_for`, etc.) as "available in specs after
`spec/spec_helper.rb` loads" — but `spec_helper.rb` does not load, so none of
them are available to anything, because nothing has ever been written to use
them. This isn't a gap that was excused in words (no "TODO", no "for now")
— it's a gap that was never mentioned at all in anything committed, which is
the quieter and easier-to-miss version of the same problem the grep is
looking for.

## Finding 4: translation gap is the one thing in this audit that is
## reported honestly and should be named as a positive example

Unlike the above, `.reports/component-inventory.md` and the commit message
for `54b3308` both state outright that gettext integration does not exist
and that checking out `po/` is not translation parity. This is the behavior
the task is asking every other finding here to be checked against, and on
this one point the project meets it. See `.reports/translation-parity.md`
for why the gap itself is still large regardless.

## Verdict

Not clean. Two false-or-stale green claims stand in committed reports
(Findings 1–2), one gap was never disclosed at all (Finding 3), and this
round's own runtime gate reports a 0/0 result that this audit is bound to
treat as a failure regardless of what a manual rerun shows.
