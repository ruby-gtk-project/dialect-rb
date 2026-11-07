# Test parity — dialect-rb vs upstream `origin/main`

## Upstream has no test suite

`git ls-tree -r --name-only origin/main | grep -iE 'test|spec'` returns
nothing. Upstream's CI (`.github/workflows/CI.yml`) runs `codespell` and a
Flatpak build with `run-tests: true`, but there is no `test/`/`tests/`
directory anywhere in the Python source — `run-tests` has nothing to run.
"Port every upstream test" is vacuously satisfied: there are zero to port.
That does not mean nothing is owed — a GUI app with no upstream tests still
needs *some* way to verify the port behaves like the original, which is what
the rest of this report checks.

## The rspec suite is still scaffolding only, and still cannot load — unchanged from last round

`spec/` contains exactly two files: `spec_helper.rb` and `README.md`. Zero
`*_spec.rb` files exist anywhere in the repo. Re-run this round:

    nix develop --command ruby -e 'require "rspec/core"; exit RSpec::Core::Runner.run(["--format","progress","--require","spec_helper","spec"])'
    → LoadError: cannot load such file -- kettle/test/rspec
    → 0 examples, 0 failures, 2 errors occurred outside of examples

Nothing about this has changed since the gem was last reported broken: the
harness `spec/README.md` describes in detail (`stub_env`, `block_is_expected`,
`pending_for`, etc.) is unreachable because `spec_helper.rb` cannot even
`require` its own stated dependency in this dev shell. This is a suite that
has never been executed successfully — unverified, not done, regardless of
how complete the README's description of it reads.

## The real verification is `test/drive_dialect.rb`, and it is not a port of any upstream test

`test/drive_dialect.rb` (2040 lines, 46 `d.step` blocks) plus
`test/gtk_driver.rb` — "copied unchanged from the reference harness in
tally-rb" per `.reports/drive-harness.md` — is a house-written headless UI
driver, not a port of any upstream test, because none exist. It is the
project's actual test suite in practice. Re-run this round, independently:

    nix develop --command xvfb-run -a ruby test/drive_dialect.rb
    → 547 of 547 checks passed / DRIVE OK

This matches the round's own runtime gate (`drive_ok=true`, 547/547, 37
components) exactly, and is a real result, not a rubber stamp — it drives the
live `Adw::ApplicationWindow`, round-trips settings to disk, exercises the
search provider over a real D-Bus session bus, and (per step 41) explicitly
asserts that `win.listen-src`/`win.listen-dest` are *not* registered, rather
than papering over that absence.

**But it took about 15 minutes of wall-clock time to get that result**, on a
machine running dozens of other forks' concurrent `xvfb-run`/`ruby`
processes (36+ Xvfb-related processes observed via `ps aux` during this
session), and a first attempt under an external 300-second timeout produced
no output at all before being killed. This is the same non-determinism the
previous round's reports flagged (gate reported `drive_ok=false, 0/0` then,
against a clean manual 542/542) — it reproduced again this round, just in
the other direction (gate green, my own first attempt silent/timed out). The
gate's 547/547 this round is corroborated by my own eventual rerun, so I am
not disputing this round's result — but a suite whose pass/fail depends on
how loaded the shared machine happens to be when it is run is not a
reliable verification signal on its own merits, and that underlying fragility
is unresolved across two rounds now.

## A specific gap the drive suite itself does not exercise

Step 19 ("the shortcuts window lists upstream's shortcuts") checks
`ShortcutsWindow::SECTIONS.length == 3` and labels the check "it has
upstream's three groups" (`test/drive_dialect.rb:976`). Upstream's
`shortcuts.blp` has **four** `ShortcutsGroup`s (Translator, Text-to-Speech,
Navigation, General), not three. No check anywhere in the 547 asserts that
the Text-to-Speech group is absent, or that it should exist — the suite is
internally consistent with the port's own (incomplete) shape, not with
upstream's. A component no check exercises against the right target is
unverified, not done, exactly per this audit's ground rule. See
`accountability-ensurance.md` for why this is a false-green finding, not
just a missing-coverage one.

## Verdict

- Upstream test parity: vacuous (0 upstream tests) — not a gap in the "port
  every test" sense.
- rspec suite: scaffolded, still cannot load its own harness gem. **Gap,
  unchanged.**
- `drive_dialect.rb`: real, substantial, reproduced green this round
  (547/547, matching the gate). **But** (a) it is slow and occasionally
  silent/non-terminating under shared-machine load, a reliability gap that
  has now shown up in two consecutive rounds, and (b) at least one of its own
  checks asserts the port's shape against itself rather than against
  upstream (the "three groups" check), which is a false-green pattern, not
  mere undercoverage. **Gap.**
