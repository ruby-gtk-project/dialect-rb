# Accountability ensurance — dialect-rb

Grep for excuse language, per the task's word list:

    grep -rniE "TODO|FIXME|not implemented|for now|in a future" lib exe .reports
    → no new matches in lib/exe (the only hits are this report's own grep
      command and its own prose quoting it)

    find . -iname "PORTING.md" -not -path './.git/*'
    → none exists

No excuse-language hits in `lib/` or `exe/`, and there is no `PORTING.md` to
check. On that narrow grep the tree is clean, same as last round. The real
findings, again, are structural — and this round adds a new, more serious
kind: a false claim baked into a passing check itself, not just a stale
document sitting next to the code.

## Finding 1 (most serious, new this round): a passing check in the drive suite asserts the port's own shape against itself, not against upstream

`test/drive_dialect.rb:976`:

    d.check("it has upstream's three groups") { ShortcutsWindow::SECTIONS.length == 3 }

This check passes — it is part of this round's 547/547 green. But upstream's
`dialect/shortcuts.blp` has **four** `ShortcutsGroup`s: Translator,
Text-to-Speech, Navigation, General (`shortcuts.blp:1-89`). The port has
three because it never ported the Text-to-Speech group. The check's label
says "upstream's three groups" as if three were upstream's count; it is not.
This is exactly the pattern the task calls the most serious kind of finding:
**a green claim that rests on something never executed against the real
target** — here, never checked against upstream's actual shortcuts.blp at
all, just against the port's own (incomplete) `SECTIONS` constant restated as
"upstream's." A reviewer reading only the drive output sees "ok" next to a
sentence that is false on its face. See `component-identification.md` and
`component-parity.md` for the underlying gap (the missing Text-to-Speech
group and its two shortcuts); this finding is about the check lying about
upstream's shape, which is a distinct and worse problem than the gap itself.

## Finding 2: `.reports/drive-harness.md` is stale again, by a larger margin than last round

`.reports/drive-harness.md` still states:

> "Last run (2026-11-07): **536 of 536 checks passed — DRIVE OK**, 42 steps,
> 9 screenshots, confirmed over two consecutive clean runs."

That was already flagged stale last round against a 542/542 claim. Two
commits later (`54b3308`'s search-provider work, then `c3fcdf9`'s speech
button wiring), the suite now stands at **547 of 547**, 46 steps — confirmed
by independently re-running it this round — and `drive-harness.md` was not
touched by either commit (`git log --oneline -- .reports/drive-harness.md`
still ends at `e4ffcd9`). The document now understates the suite by 11
checks and 4 steps, not the 6/0 gap from last round. Nobody has fixed the
staleness this task itself flagged last round; it has simply grown. This is
the second consecutive round in which a committed report's own numbers are
behind the code it claims to describe.

## Finding 3: the rspec suite's green is as false as it gets — unchanged, still never mentioned anywhere in committed prose

`spec/` has zero spec files and a `spec_helper.rb` that still fails to
`require "kettle/test/rspec"` under the project's own dev shell, reproduced
again this round. `spec/README.md` documents a rich set of helpers as
"available in specs after `spec/spec_helper.rb` loads" — it does not load,
so none of them are available to anything, because nothing has ever been
written to use them. No commit message, report, or comment anywhere in the
tree says the rspec harness is broken; it is a gap that was never named at
all, the quieter and easier-to-miss version of the problem the grep looks
for.

## Finding 4: translation gap is still reported honestly, and still large

Unlike the above, `component-identification.md`, `component-parity.md` and
`translation-parity.md` all continue to state outright that gettext
integration does not exist. This is the behavior the task asks every other
finding to be checked against, and the project continues to meet it here.
0 of 123 msgids are reachable at runtime regardless.

## Finding 5: this round's runtime gate is corroborated, but only after a reproduction that itself recreates last round's unresolved reliability problem

This round's gate: `drive_ok=true`, 547/547, 37 components. I independently
reran `test/drive_dialect.rb` and got the identical 547/547 result, so this
round's gate is not contradicted the way last round's was. But getting that
result took on the order of 15 minutes on a machine running 36+ other
Xvfb-related processes from concurrent forks, and a first attempt under an
external 300-second timeout produced no output at all. That is the same
failure mode last round's reports raised as unresolved (a drive run that
sometimes hangs indefinitely under shared-machine load) recurring a second
time, just with the gate landing on the green side of the coin-flip this
time instead of the red side. Treating 547/547 as solid ground truth for
*this* round is reasonable since I reproduced it myself — but the underlying
fragility that makes the gate's number round-to-round inconsistent on
identical code is still nobody's fixed problem, and it is the second round
running that this audit has had to spend significant time working around it
rather than trusting either the gate or a single manual run at face value.

## Verdict

Not clean. One new false-green finding this round (Finding 1 — a check that
misstates upstream's own shape, not merely a stale document) is more serious
than anything found last round. The previously-known stale report (Finding 2)
was not fixed and has grown more stale. The rspec gap (Finding 3) remains
completely undisclosed anywhere in the tree. The translation gap (Finding 4)
remains honestly disclosed. The drive-harness reliability problem (Finding 5)
recurred for the second consecutive round.
