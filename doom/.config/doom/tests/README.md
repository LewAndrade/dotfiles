# Org workflow checks

Run these checks after changing capture, agenda layout, calendar helpers, or
the notes-backup guard. They use disposable Org files, mocked calendar requests,
and fake authorization data, not the live calendar or notes repository.

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
  -f ert-run-tests-batch-and-exit
```

The suite loads the workflow, automatic sync, Keychain, recurrence, graphical
week, and status-icon tests. A successful run ends with `0 unexpected`.
It checks primary-ID approval, Work/task isolation, conflict handling, recurring
edit scope, read-only week data, compact Today versus full-width Review, zoom
cleanup, and status visibility and mouse bindings.

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

## Limits and live checks

Batch tests do not prove GUI placement, actual mouse clicks, Google permissions,
restart resumption, or natural token expiry. GUI checks have confirmed the week
opens in the main window and the icon retains its mouse bindings in Doom's
modeline. Disposable-calendar live tests covered two-way sync, recurrence,
conflicts, offline recovery, and Work/task isolation before the approved primary
switch. The primary import and a fresh Keychain-backed background refresh passed.
An actual restart and natural token-expiry check remain deferred.

Do not put credentials, calendar contents, or occurrence caches into test
fixtures. Do not call raw `org-gcal-sync` or `org-gcal-fetch` to verify sync;
they bypass the custom safeguards. Use the guarded controls in `SPC n g`.
