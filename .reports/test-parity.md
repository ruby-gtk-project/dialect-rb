# Test parity — dialect-rb vs upstream `origin/main`

## Upstream has no test suite

`git ls-tree -r --name-only origin/main | grep -iE 'test|spec'` returns
nothing. Upstream's CI (`.github/workflows/CI.yml`) runs `codespell` and a
Flatpak build with `run-tests: true`, but there is no `test/`/`tests/`
directory anywhere in the Python source — `run-tests` has nothing to run.
"Port every upstream test" is vacuously satisfied: there are zero to port.
That does not excuse the port from having some way to verify it behaves like
the original, which is what the rest of this report checks.

## The rspec suite is still scaffolding only, and still cannot load — unchanged for a third round

`spec/` contains exactly two files: `spec_helper.rb` and `README.md`. Zero
`*_spec.rb` files exist anywhere in the repo. Re-run this round:

    nix develop --command ruby -e 'require "rspec/core"; exit RSpec::Core::Runner.run(["--format","progress","--require","spec_helper","spec"])'
    → LoadError: cannot load such file -- kettle/test/rspec
    → 0 examples, 0 failures, 2 errors occurred outside of examples

Identical to both previous rounds. The rich harness `spec/README.md`
describes (`stub_env`, `block_is_expected`, `pending_for`, etc.) is
unreachable because `spec_helper.rb` cannot even `require` its own stated
dependency in this dev shell. No commit in this round's range touched
`spec/` or the `Gemfile`. **This is a suite that has never once been
executed successfully, across three audit rounds — unverified, not done.**

## The real verification is `test/drive_dialect.rb`, and it is not a port of any upstream test

`test/drive_dialect.rb` (2074 lines, 49 `d.step` blocks) plus
`test/gtk_driver.rb` is a house-written headless UI driver, not a port of
any upstream test, because none exist. It is the project's actual test suite
in practice. This round's own runtime gate reports `drive_ok=true`, 557/557,
45 components — three more steps and ten more checks than the previous
round's 547/547, matching the TTS-related work (`bc3e087`, `fc10569`) that
landed since.

I independently re-ran it this round:

    nix develop --command xvfb-run -a ruby test/drive_dialect.rb

This machine is shared: `ps aux` at the start of this run showed **six other**
`test/drive_dialect.rb` Ruby processes already running under other Xvfb
displays — one left over from the previous day, five more started earlier
the same morning — plus 15+ Xvfb server processes total. That is independent,
first-hand confirmation of the exact contention `test-parity.md` and
`accountability-ensurance.md` have now flagged as unresolved for two
consecutive prior rounds, reproducing a third time.

**This round's re-run did not finish inside this audit's own time budget.**
It ran for over eight minutes, during which the screenshots in `tmp/shots/`
updated in order through `04-before-close.png` — step 49 of 50, the
second-to-last step — confirming the run was progressing correctly and had
not hung, but it had not reached the final step or printed its summary line
by the time this report had to be written up. I did not get an independent
pass/fail number from my own run this round. The only number on record is
the task's own runtime gate (`drive_ok=true`, 557/557, 45 components), which
I am **not** independently corroborating this round the way the previous
two rounds' reports did — the closest I have is that my own run reached the
second-to-last of its screenshots cleanly, consistent with the gate's claim
but not a substitute for it.

This is itself the finding worth stating plainly: a verification run that
takes long enough, often enough, on this shared fleet that an auditor cannot
reliably reproduce the gate's number inside one round's time budget is not
a dependable verification signal, regardless of which way any single
round's number comes out. Two previous rounds reproduced it manually within
budget (taking ~15 minutes each); this round did not finish within the time
available. That is three consecutive rounds in which this exact harness's
reliability has been the thing this audit spent time on, not just the thing
it set out to check.

## A specific gap the drive suite does not — and, by design, cannot — exercise

`lib/session.rb`'s header comment (see `component-parity.md` and
`accountability-ensurance.md`) discloses that the port's synchronous
`Soup::Session#send_and_read` call does not release Ruby's GVL, so a slow
real provider can stall the whole process for the length of a request —
behavior upstream's asyncio coroutines do not have. `test/drive_dialect.rb`
cannot catch this even in principle, because its own `DriveProvider` answers
from an in-memory array with no real I/O at all, by design (the task
notes explicitly why: driving the real window against a real provider would
make the run depend on the internet). This is not a flaw in the drive
script's design — a network-independent harness is the right call — but it
does mean this behavioral difference has zero test coverage on either side
of the comparison, and no document before this round named it as such.

## Verdict

- Upstream test parity: vacuous (0 upstream tests) — not a gap in the "port
  every test" sense.
- rspec suite: scaffolded, still cannot load its own harness gem, three
  rounds running. **Gap, unchanged.**
- `drive_dialect.rb`: real, substantial, grown by 3 steps / 10 checks this
  round to match the TTS work. The gate's claimed 557/557 is **not**
  independently corroborated by this round's audit — my own re-run was still
  in progress, having reached the second-to-last of its screenshots cleanly
  (no hang, no visible failure), when this round's time budget ran out. The
  gate's number should be treated as asserted, not reproduced, this round.
  **This reliability gap is itself unchanged** across three rounds now and
  is a gap in its own right, independent of whatever the gate's number says.
- The session's blocking-I/O behavior under a real, slow provider has no
  coverage anywhere, by the harness's own necessary design choice. Recorded
  as an acknowledged, structural coverage gap rather than an omission.
