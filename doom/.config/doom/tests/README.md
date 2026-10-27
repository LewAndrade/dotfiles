# Org workflow checks

Run these checks after changing capture, agenda layout, Calendar helpers,
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

## Run the calendar and agenda suite

Run from `doom/.config/doom` with Emacs 30.2 and this checkout's installed Doom
packages. The command adds the existing Straight build directories to the load
path without loading your live Doom config or private calendar settings.
Update the `build-30.2` path if your installed Emacs version differs.

```sh
emacs -Q --batch \
  --eval '(dolist (dir (directory-files (expand-file-name "~/.config/emacs/.local/straight/build-30.2") t "^[^.]")) (when (file-directory-p dir) (add-to-list (quote load-path) dir)))' \
  --eval '(progn (require (quote org-super-agenda)) (org-super-agenda-mode 1) (require (quote org-modern)) (add-hook (quote org-agenda-finalize-hook) (function org-modern-agenda)))' \
  -l tests/org-calendar-repeat-test.el \
  -l tests/org-sync-ui-test.el \
  -f ert-run-tests-batch-and-exit
```

The suite loads the workflow, automatic Calendar sync, Keychain, recurrence, graphical
week, and status-icon tests. A successful run ends with `0 unexpected`.
It checks primary-ID approval, Work isolation, conflict handling, recurring
edit scope, week data and editing (create, move, rename, cancel, undo, refusals), compact Today versus full-width Review, zoom
cleanup, and status visibility and mouse bindings.
The shared UI checks the named badge, its click target, selective hover help,
display-only refresh, panel actions, paused-sync guards, safe error reporting,
and last-success timestamps. They also check Keychain controls and removal of the
old shortcut trees. They never use live accounts or files.

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

## Personal sync controls

Click the named `[Cal]` modeline badge or use `SPC n i` to open the shared panel.
The badge appears in relevant views and wherever a sync problem needs attention.
It has a left-click target and a right-click action menu.
Hover shows a native tooltip; unrelated hover help stays disabled. Native hover placement still needs a manual check on your display.

In the panel, use `c` for Calendar, then `s` to sync, `a` to
authorize, `p` to pause/resume, or `d` for the existing detailed review screen.
Use `g` to refresh displayed information only and `q` to close the panel.
Buttons provide the same actions. When paused, the panel has no Sync button,
and the keyboard action refuses to bypass the pause.

The Keychain section offers Set up / update and Forget unlock. Forget asks for
confirmation and keeps encrypted tokens and Org files. Use `TAB` or `Shift-TAB`
to select buttons and `RET` to activate one.
View shortcuts (`SPC n d`, `SPC n r`, `SPC n v`) and agenda-local editing stay
unchanged. In the panel's Evil Emacs state, use `M-SPC` for Doom's leader.

Opening the panel, hovering, or opening an action menu never starts a sync,
saves a source file, or starts Google sign-in. The panel updates when sync status
changes without taking focus. Last-attempt and last-success times cover the
current Emacs session; an unknown time is shown as not recorded, not inferred
from the current healthy status. Authorization, private state, and conflict
resolution stay inside the Calendar integration.

After loading or restarting Emacs, check `SPC n i`, the badge click target,
hover placement, and the panel's single-key actions. Batch tests do not prove
native mouse behavior, GUI placement, or startup behavior in the full Doom UI.

## Limits and live checks

Batch tests do not prove GUI placement, actual mouse clicks, Google permissions,
restart resumption, or natural token expiry. GUI checks have confirmed the week
opens in the main window and the icon retains its mouse bindings in Doom's
modeline. Disposable-calendar live tests covered two-way sync, recurrence,
conflicts, offline recovery, and Work isolation before the approved primary
switch. The primary import and a fresh Keychain-backed background refresh passed.
An actual restart and natural token-expiry check remain deferred.

Do not put credentials, calendar contents, or private sync caches into test
fixtures. Do not call raw `org-gcal-sync` or `org-gcal-fetch` to verify sync;
they bypass the custom safeguards. Use the guarded controls in Integrations
(`SPC n i`).
