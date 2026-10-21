# Org workflow checks

Run these checks after changing capture, agenda layout, Calendar/Tasks helpers,
keybindings, or the notes-backup guard. They use disposable Org files, mocked
calendar requests, and fake authorization data, not the live calendar or notes
repository.

## Run the keybinding checks

From `doom/.config/doom`:

```sh
emacs -Q --batch -l tests/keybindings-test.el -f ert-run-tests-batch-and-exit
```

These inspect the literate configuration without loading Doom. They check
`SPC t u` for the theme toggle and agent-shell's `, n` for naming and `, f` for
forking, removal of the uppercase aliases, and matching help text. Check the
effective bindings in a running Doom session too; these tests do not load its
keymaps.

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
  -l tests/org-sync-ui-test.el \
  -f ert-run-tests-batch-and-exit
```

The suite loads the workflow, automatic Calendar/Tasks sync, Keychain, recurrence, graphical
week, and status-icon tests. A successful run ends with `0 unexpected`.
It checks primary-ID approval, Work/task isolation, conflict handling, recurring
edit scope, read-only week data, compact Today versus full-width Review, zoom
cleanup, and status visibility and mouse bindings.
The shared UI checks named badges, separate click targets, selective hover help,
display-only refresh, selected-integration actions, paused-sync guards, safe error
reporting, and last-success timestamps. They also check Keychain controls,
task/block pickers, changed-link protection, and removal of the old shortcut
trees. They never use live accounts or files.
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
with Authorize Tasks in Integrations (`SPC n i`). After an insufficient-scope
error, this explicitly requests new Tasks consent instead of reusing the partial
token. It does not replace Calendar's token.

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
their completion and reopening normally. `SPC n i` opens Integrations with
Calendar and Tasks controls. The separate Calendar and Tasks shortcut trees have
been removed; the panel calls the same guarded functions.

## Personal sync controls

Click either named modeline badge or use `SPC n i` to open the shared panel.
The badges appear together in relevant views and wherever a sync problem needs
attention. Each badge has its own left-click target and right-click action menu.
Hover shows a native tooltip for that integration; unrelated hover help stays
disabled. Native hover placement still needs a manual check on your display.

In the panel, use `c` for Calendar or `t` for Tasks, then `s` to sync, `a` to
authorize, `p` to pause/resume, or `d` for the existing detailed review screen.
Use `g` to refresh displayed information only and `q` to close the panel.
Buttons provide the same actions. A paused integration has no Sync button,
and the keyboard action refuses to bypass the pause.

The Keychain section offers Set up / update and Forget unlock. Forget asks for
confirmation and keeps encrypted tokens and Org files. The local time-block
section offers Link, Visit, and Unlink with task pickers, so no agenda selection
is required. Use `TAB` or `Shift-TAB` to select buttons and `RET` to activate one.
View shortcuts (`SPC n d`, `SPC n r`, `SPC n v`) and agenda-local editing stay
unchanged. In the panel's Evil Emacs state, use `M-SPC` for Doom's leader.

Opening the panel, hovering, or opening an action menu never starts a sync,
saves a source file, or starts Google sign-in. The panel updates when sync status
changes without taking focus. Last-attempt and last-success times cover the
current Emacs session; an unknown time is shown as not recorded, not inferred
from the current healthy status. Authorization, private state, and conflict
resolution remain separate for Calendar and Tasks.

After loading or restarting Emacs, check `SPC n i`, both badge click targets,
hover placement, and the panel's single-key actions. Batch tests do not prove
native mouse behavior, GUI placement, or startup behavior in the full Doom UI.

## Creation retries and cache locks

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

1. Open Integrations with `SPC n i` and choose Link under Local time-block links.
2. Select the Personal task, then its Calendar time block, and confirm the exact
   pair and time.
3. Check Today/Review or the graphical week. The combined row uses the task's
   state and the block's time. `RET` visits the task; Visit in Integrations offers
   a task picker and opens its Calendar source.

Use Unlink in Integrations to restore separate displays. Pairing changes only a private
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
unchanged. The link file's `0600` permissions and the original three leader
bindings were verified in the running Emacs before those controls moved into
Integrations. No Google writes were made for pairing.

Do not put credentials, calendar contents, or private sync caches into test
fixtures. Do not call raw `org-gcal-sync` or `org-gcal-fetch` to verify sync;
they bypass the custom safeguards. Use the guarded controls in Integrations
(`SPC n i`).
