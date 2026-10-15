# Org workflow checks

Run these checks after changing capture, agenda layout, Calendar/Tasks helpers, or
the notes-backup guard. They use disposable Org files, mocked calendar requests,
and fake authorization data, not the live calendar or notes repository.

## Run the calendar, Tasks, and agenda suite

Run from `doom/.config/doom` with Emacs 30.2 and this checkout's installed Doom
packages. The command adds the existing Straight build directories to the load
path without loading your live Doom config or private calendar settings.
Update the `build-30.2` path if your installed Emacs version differs.

```sh
emacs -Q --batch \
  --eval '(dolist (dir (directory-files (expand-file-name "~/.config/emacs/.local/straight/build-30.2") t "^[^.]")) (when (file-directory-p dir) (add-to-list (quote load-path) dir)))' \
  --eval '(progn (require (quote org-super-agenda)) (org-super-agenda-mode 1) (require (quote org-modern)) (add-hook (quote org-agenda-finalize-hook) (function org-modern-agenda)))' \
  -l tests/org-calendar-repeat-test.el \
  -l tests/org-tasks-sync-test.el \
  -l tests/org-tasks-blocks-test.el \
  -f ert-run-tests-batch-and-exit
```

The suite loads the workflow, automatic Calendar/Tasks sync, Keychain, recurrence, graphical
week, and status-icon tests. A successful run ends with `0 unexpected`.
It checks primary-ID approval, Work/task isolation, conflict handling, recurring
edit scope, read-only week data, compact Today versus full-width Review, zoom
cleanup, and status visibility and mouse bindings.
The local task/block tests check explicit identity pairing, one timed task row,
native state actions, completion/reopening, rescheduling, Review deduplication,
deadlines, Work isolation, and separate displays for unsupported or conflicting
plans. They also check that pairing and rendering never save source files or
contact Google, and that corrupt links and duplicate identities never hide rows.

## Run the backup-guard checks

From `doom/.config/doom`, check the Emacs launcher without starting a backup or
installing its timer:

```sh
emacs -Q --batch -l tests/org-backup-test.el -f ert-run-tests-batch-and-exit
```

From the repository root, check the shell runner with fake Git:

```sh
python3 -m unittest discover -s scripts/tests -p 'test_org_backup.py'
```

The launcher checks that a live process is retained and new runs stay
asynchronous. The runner checks overlapping runs, existing-lock preservation,
and lock cleanup after successful and failed runs. It never commits or pushes
real notes. Use these tests rather than triggering a real backup as a test.

## Run the Tasks setup checks

From `doom/.config/doom`, use the same installed-package load path for the
separate Tasks authorization tests:

```sh
emacs -Q --batch \
  --eval '(dolist (dir (directory-files (expand-file-name "~/.config/emacs/.local/straight/build-30.2") t "^[^.]")) (when (file-directory-p dir) (add-to-list (quote load-path) dir)))' \
  -l tests/org-tasks-access-test.el \
  --eval '(ert-run-tests-batch-and-exit "my/tasks-access")'
```

These check separate provider/token handling, verified Personal account identity,
worker serialization, consent, cancellation, private output, and read-only list
pagination. Setup requests `tasks`, `openid`, and `email`; account verification
must pass before a Tasks token is stored or returned to Emacs. Calendar retains
its own encrypted record. The setup command itself never imports or mutates tasks;
automatic sync is enabled separately by the private account/list approval.
If a consent screen granted only part of the requested access, repeat setup
with `SPC n g m t`. After an insufficient-scope error, this explicitly requests
new Tasks consent instead of reusing the partial token. It does not replace
Calendar's token.

## Tasks sync safeguards

`org-tasks-sync-test.el` adds disposable-file and fake-server checks for both
directions, paginated phone imports, hidden completions, completion/reopening,
independent-field merges, conflict choices, reviewed cancellation/deletion,
restoration, unsaved and external edits, Work isolation, local repeaters, and
private-note preservation. It also checks lost creation replies, stale ETags,
stable polling, exact account/list/file mappings, private cache permissions,
cross-instance locks, review buttons, and silent background authorization.

Normal sync covers all Personal tasks in `personal.org` and one exact existing
Google list. Shared fields are title, scheduled day (`due` in the API), and
completion. No Org or Google notes are transmitted or replaced. Org time,
duration, deadline, and recurrence are not represented in the shared payload.
See the [Google Tasks resource reference](https://developers.google.com/workspace/tasks/reference/rest/v1/tasks).

Private `org-tasks.el` approves `my/org-tasks-account` and `my/org-tasks-list-id`.
The per-scope JSON cache and encrypted token store belong beside it, outside Git.
The first list read records historical completions to exclude from imports.
Reopening one on the phone brings it into scope. Linked tasks continue syncing
their completion and reopening normally. `SPC n T s` opens review; `SPC n T p`
pauses/resumes; `SPC n T g` is a guarded manual request, disabled while paused.

An uncertain creation is journaled before POST and never automatically retried.
Review offers linking a matching Google task or an explicitly confirmed retry
after checking Google. An existing cache lock is never removed automatically:
inspect its `pid`, confirm that process has stopped, and review pending creations
before removing only that scope's lock directory. Do not discard the cache to
"fix" a creation problem.

## Limits and live checks

Batch tests do not prove GUI placement, actual mouse clicks, Google permissions,
restart resumption, or natural token expiry. GUI checks have confirmed the week
opens in the main window and the icon retains its mouse bindings in Doom's
modeline. Disposable-calendar live tests covered two-way sync, recurrence,
conflicts, offline recovery, and Work/task isolation before the approved primary
switch. The primary import and a fresh Keychain-backed background refresh passed.
Live Tasks checks in the approved existing list passed creation in both
directions, title/date edits, completion/reopening, unscheduling, private-note
and richer-planning preservation, conflict review, and explicitly approved
deletion. Both disposable tasks were removed locally and confirmed deleted in
Google. The 16 historical completions were initially left untouched, then deleted
on explicit request after checking their IDs and unchanged completed state; all
16 were confirmed absent or deleted. Google also rejected a
stale-ETag write with HTTP 412. A fresh Tasks background grant refresh through
Keychain passed without consent or an unlock prompt.
An actual restart and natural token-expiry check remain deferred.

## Confirm a local task/time-block pair

Google Tasks shares only the scheduled day. A native timed task can also expose
a Calendar `focusTime` block without an API association. Never infer that
association from matching titles or hide all focus-time events.

With both integrations configured, synced sources saved, and sync idle:

1. Select the Personal task in Org or the agenda and use `SPC n T l`.
2. Select its Calendar time block and confirm the exact pair and time.
3. Check Today/Review or the graphical week. The combined row uses the task's
   state and the block's time. `RET` visits the task; `SPC n T b` visits the block.

Use `SPC n T u` to restore separate displays. Pairing changes only a private
`org-task-blocks-<scope>.json` file beside the Tasks cache, with mode `0600` and
an atomic write protected by a scope-specific lock. It does not change Org
planning, Google objects, or completion on the separate Calendar event.
Completed pairs follow Org's existing done-task visibility rules.

Only unique, same-day, non-recurring focus-time pairs with a date-only task are
combined. Conflicts, Calendar edits awaiting sync, differing dates, restored
identities, or an independent local task time leave the sources separate. Status
explains inactive links. Change block times through the Calendar source; ordinary
task scheduling changes only the task. No companion Calendar events are created.

One existing completed pair was enabled live after validating both exact IDs and
the time range. Its separate event row was hidden and both source buffers remained
unchanged. The link file's `0600` permissions and all three leader bindings were
verified in the running Emacs. No Google writes were made for pairing.

Do not put credentials, calendar contents, or private sync caches into test
fixtures. Do not call raw `org-gcal-sync` or `org-gcal-fetch` to verify sync;
they bypass the custom safeguards. Use the guarded controls in `SPC n g`.
