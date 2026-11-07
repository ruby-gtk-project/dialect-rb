# Component identification — dialect-rb vs upstream `origin/main`

Method: `component-scan.sh` run against a clean checkout of `origin/main` (via
`git archive`) and against `lib/` on `ruby`, cross-checked by hand against the
Python/blueprint source and the existing `.reports/component-inventory.md`
(37 units, produced in an earlier round and still accurate as a unit map).
This report does not re-litigate that unit map; it records what the scan adds
and what it gets wrong, which is where this round's actual findings are.

## Scan totals

| | rows |
|---|---:|
| upstream (`/tmp/upstream_dialect/dialect`) | 265 |
| port (`lib/`) | 170 |

A raw row-count gap of ~95 looks alarming but is mostly scanner noise, not
missing widgets — see below. The real unit-level gaps are the two already on
record in `component-inventory.md`: unit 11 (speech button not wired into the
window) and unit 37 (po/ checked out, zero gettext integration).

## Scanner false negatives, verified by reading the source

`comm -23` between the two symbol sets reports `win.back`, `win.forward`,
`win.clear`, `win.copy`, `win.font-size-inc`, `win.font-size-dec` as present
upstream and absent from the port. Reading `lib/window.rb` shows all six are
implemented — the scan's regex expects a literal `install_action('win.copy',
...)`-shaped call and misses the house pattern actually used:

```ruby
# lib/window.rb:466-467, 556, 624
def return_btn = @return_btn ||= action_button('win.back', ...)
def forward_btn = @forward_btn ||= action_button('win.forward', ...)
def clear_btn = @clear_btn ||= action_button('win.clear', ...)
@copy_btn ||= action_button('win.copy', ...).tap { ... }

# lib/window.rb:965-974 — dispatch table, not a literal action name per call
when 'back' then on_back_action
when 'forward' then on_forward_action
when 'clear' then on_clear_action
when 'copy' then on_copy_action
```

This is exactly the "actions whose name is never a literal" trap the
component-identification skill calls out. Confirmed present: `win.back`,
`win.forward`, `win.clear`, `win.copy`, `win.font-size-inc`, `win.font-size-dec`.
Not a gap.

## Scanner false negative confirmed as a real, already-documented gap

`win.listen-src` / `win.listen-dest` are also absent from the port-side scan —
but here reading the source confirms the absence is real, not a scanner
artifact: `lib/window.rb` installs no such actions anywhere, and
`lib/speech_button.rb` is never instantiated by the window. This matches unit
11 in `component-inventory.md` and is independently confirmed by
`test/drive_dialect.rb` unit 41, which asserts the absence directly (`win.listen-src
is not registered`, `win.listen-dest is not registered`, `there is no speech
button class`, `and no speech button in the source toolbar`) rather than
pretending it is done.

## Translation-adjacent component: po/ submodule

`po/` is a checked-out git submodule (`dialect-app/po`), containing
`po/ui/dialect.pot` with 123 `msgid` entries. It is not a widget, but it is a
component boundary the inventory should name explicitly: it exists in the
tree and is wired into nothing. See `.reports/translation-parity.md`.

## Conclusion

No new missing widget, signal or CSS class was found beyond what
`component-inventory.md` already lists. The scan's apparent extra gaps (the
six `win.*` actions above) are false negatives from the dispatch-table style;
the one scanner-flagged absence that is real (`win.listen-src`/`win.listen-dest`)
was already on record. This report exists to confirm that record against a
fresh, independent scan rather than to add to it — see `component-parity.md`
for the behavioral comparison and the one gap that matters: unit 11.
