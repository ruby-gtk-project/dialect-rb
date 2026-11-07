# Test parity — dialect-rb vs upstream `origin/main`

## Upstream has no test suite

`git ls-tree -r --name-only origin/main | grep -iE 'test|spec'` returns
nothing. Upstream's CI (`.github/workflows/CI.yml`) runs `codespell` and a
Flatpak build with `run-tests: true`, but there is no `test/` or `tests/`
directory anywhere in the Python source — `run-tests` has nothing to run.
So "port every upstream test" is vacuously satisfied: there are zero to port.
That does not mean nothing is owed here — a GUI app with no upstream tests
still needs *some* way to verify the port behaves like the original, which is
what the rest of this report checks.

## The rspec suite exists as scaffolding only, and is currently broken

`spec/` contains exactly two files: `spec_helper.rb` and `README.md`. Zero
actual spec files (`*_spec.rb`) exist anywhere in the repo. The harness is
not just empty, it does not load. The dev shell's own banner names the
command to run it:

    ruby -e 'require "rspec/core"; exit RSpec::Core::Runner.run(["--format", "progress", "--require", "spec_helper", "spec"])'

Running it (this session, inside `nix develop`):

    An error occurred while loading spec_helper.
    Failure/Error: require "kettle/test/rspec"
    LoadError: cannot load such file -- kettle/test/rspec
    0 examples, 0 failures, 2 errors occurred outside of examples

`bundle exec rspec` fails the same way one layer earlier — `rspec-core is not
currently included in the bundle`. The `kettle-test` gem `spec/README.md`
describes as the harness is not resolvable in this dev shell at all. This is
a suite that has never been executed successfully, exactly the kind of gap
the task calls out by name: it is unverified, not done, regardless of how
complete `spec/README.md`'s description of its helpers reads.

## The real verification is `test/drive_dialect.rb`, and it is not an upstream port

`test/drive_dialect.rb` (2008 lines) plus `test/gtk_driver.rb` is a
house-written headless UI driver — "copied unchanged from the reference
harness in tally-rb" per `.reports/drive-harness.md` — not a port of any
upstream test, because none exist. It is the project's actual test suite in
practice, and it does run:

    nix develop --command xvfb-run -a ruby test/drive_dialect.rb
    → 542 of 542 checks passed / DRIVE OK   (fresh run, this session, exit 0)

This is real, not a rubber stamp: it drives the live `Adw::ApplicationWindow`,
asserts widget state, round-trips settings to disk, and exercises the search
provider over a real D-Bus session bus.

## The runtime gate for this round contradicts that result, and the
contradiction itself is unresolved

This round's gate reports **drive_ok=false, 0 checks passed, 0 failed**,
covering 49 components — i.e., from the harness's point of view, the drive
run did not produce a result at all this round, not even a partial fail.
My own first attempt reproduced something consistent with that: run under an
external `timeout 180`, the process was still alive and had done nothing
past 195 elapsed seconds, and never printed a result before being superseded.
A second, unconstrained run (no external timeout) completed cleanly in the
same dev shell on the same tree: 542/542, exit 0.

I cannot explain the gap between these two outcomes from inside this
session — this machine is running many other forks' drive scripts
concurrently (`ps aux` showed other ports' `xvfb-run`/`ruby` processes
throughout), so slow Xvfb/nix-develop startup under load is a plausible but
unconfirmed cause. What matters for parity accounting: **the gate's own
measurement for this round is a failure, and a failure or non-terminating
drive run is a gap in its own right per this audit's own ground rule**,
whatever a manually re-run copy later showed. Treat `drive_ok=false` as the
round's result. The discrepancy needs an explicit fix, not averaging-away:
either the harness needs to tolerate the concurrent-load environment (longer
timeout, retry, or a lock so only one fork's drive script runs at a time), or
something about the checked-in state only fails under the gate's exact
invocation and needs reproducing exactly as the gate runs it, not as I ran
it by hand.

## Verdict

- Upstream test parity: vacuous (0 upstream tests) — not a gap in the
  "port every test" sense.
- rspec suite: scaffolded, never run successfully, currently cannot load its
  own harness gem. **Gap.**
- `drive_dialect.rb`: real, substantial, passes when I run it directly.
  **But this round's own gate says the drive run failed (0/0), and that
  result, not my manual rerun, is what this audit is required to treat as
  ground truth.** Unverified-by-the-gate is a gap, full stop.
