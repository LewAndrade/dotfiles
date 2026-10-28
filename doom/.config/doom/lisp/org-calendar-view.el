;;; org-calendar-view.el --- Editable SVG week for the central Org files -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'org)
(require 'org-element)
(require 'org-timegrid-org)
(require 'iso8601)
(require 'parse-time)
(declare-function parse-iso8601-time-string "parse-time" (date))
(declare-function set-popup-rule! "doom-ui-popup" (predicate &rest plist))

(declare-function my/org-file "config" (name))
(declare-function my/org-quietly "org-calendar-config" (fn &rest args))
(declare-function my/org-calendar-repeat--effective-events "org-calendar-repeat" ())
(declare-function my/org-calendar-repeat--series-marker "org-calendar-repeat" (id))
(declare-function my/org-calendar-repeat--ensure-state "org-calendar-repeat" ())
(declare-function my/org-calendar-auto--same-file-p "org-calendar-auto" (file))
(defvar my/org-calendar-auto--calendar)
(defvar my/org-calendar-id)
(defvar my/org-calendar-repeat--events)

(defconst my/org-calendar-view-buffer "*Org Week*")
;; Doom's generic star-buffer rule otherwise opens this calendar in a drawer.
(when (fboundp 'set-popup-rule!)
  (set-popup-rule! "\\`\\*Org Week\\*\\'" :ignore t))
(defvar-local my/org-calendar-view-profile nil
  "Visible profile: nil for both, or work/personal as a string.")

(defun my/org-calendar-view--color (headline)
  "Colour HEADLINE by its existing Work/Personal category, without adding tags."
  (save-excursion
    (goto-char (org-element-property :begin headline))
    (face-foreground (if (equal (org-get-category) "Work")
                         'font-lock-keyword-face 'font-lock-string-face) nil t)))

;; The central files, shared by listing and edits.
(defconst my/org-calendar-view--files
  '("work.org" "personal.org" "calendar-work.org" "calendar-personal.org"))

(defmacro my/org-calendar-view--with-settings (auto-save &rest body)
  "Run BODY with the Org backend settings the week uses.
AUTO-SAVE is evaluated; edits save their files when it is non-nil, and saving
`calendar-personal.org' queues the Google sync."
  (declare (indent 1))
  `(let ((org-timegrid-org-files (mapcar #'my/org-file my/org-calendar-view--files))
         (org-timegrid-org-capture-file nil)
         (org-timegrid-org-auto-save ,auto-save)
         (org-timegrid-org-repeater-history nil)
         (org-timegrid-org-show-done nil)
         (org-timegrid-org-exclude-properties '(("GCAL_AUTO_RECURRING" . nil)))
         (org-timegrid-org-color-function #'my/org-calendar-view--color))
     ,@body))

(defun my/org-calendar-view--heading-marker (marker)
  "Return a live marker on the heading that owns MARKER."
  (org-with-point-at marker
    (org-back-to-heading t)
    (point-marker)))

(defun my/org-calendar-view--refuse-edit (event &rest _)
  "Signal why EVENT cannot be edited, when it cannot."
  (my/org-calendar-view--check-editable event))

(defun my/org-calendar-view--read-only-source (marker kind &optional occurrence)
  "Source for a synthetic KIND entry on the heading at MARKER, never editable."
  (list :heading-marker (my/org-calendar-view--heading-marker marker)
        :occurrence occurrence :read-only kind))

(defun my/org-calendar-view--org-events (start end)
  "Scheduled tasks and event timestamps intersecting START and END.
Each event keeps the Org backend's source, so its update and delete functions
work, plus a `:heading-marker' for visiting and filtering."
  (let (result)
    (my/org-calendar-view--with-settings nil
      (dolist (event (org-timegrid-org--list-events start end))
        (let* ((source (org-timegrid-event-source event))
               (marker (plist-get source :marker))
               (calendar-file (member (expand-file-name (plist-get source :file))
                                      (mapcar #'my/org-file '("calendar-work.org" "calendar-personal.org"))))
               (state (org-with-point-at marker (org-get-todo-state))))
          (when (if calendar-file
                    (and (null state) (eq (plist-get source :kind) 'timestamp))
                  (and (member state '("TODO" "DOING" "WAIT"))
                       (eq (plist-get source :kind) 'scheduled)))
            (unless calendar-file
              (setf (org-timegrid-event-title event)
                    (format "%s %s" state (org-timegrid-event-title event))))
            (setf (org-timegrid-event-source event)
                  (append (list :heading-marker (my/org-calendar-view--heading-marker marker)
                                :state-prefix (and (not calendar-file) state))
                          source)
                  (org-timegrid-event-metadata event)
                  (plist-put (copy-sequence (org-timegrid-event-metadata event))
                             :prepare-edit #'my/org-calendar-view--refuse-edit))
            (push event result)))))
    (nreverse result)))

(defun my/org-calendar-view--deadlines (start end)
  "Show deadlines as labelled, read-only date-rail markers, never as reserved work time."
  (let (events)
    (dolist (file (mapcar #'my/org-file '("work.org" "personal.org")))
      (when (file-readable-p file)
        (with-current-buffer (my/org-quietly #'find-file-noselect file)
          (org-with-wide-buffer
           (save-excursion
             (org-element-map (org-element-parse-buffer) 'headline
               (lambda (headline)
                 (when-let* ((timestamp (org-element-property :deadline headline)))
                   (when (member (org-element-property :todo-keyword headline) '("TODO" "DOING" "WAIT"))
                     (let* ((day (org-timegrid-org--timestamp-all-day-minutes timestamp nil))
                            (hour (org-element-property :hour-start timestamp))
                            (minute (org-element-property :minute-start timestamp)))
                       (when (and (< day end) (> (+ day 1440) start))
                         (goto-char (org-element-property :begin headline))
                         (push (org-timegrid-event-create
                                :id (list file (point) 'deadline)
                                :title (format "Due%s: %s"
                                               (if hour (format " %02d:%02d" hour minute) "")
                                               (org-element-property :raw-value headline))
                                :start day :end (+ day 1440) :all-day t
                                :color (face-foreground 'font-lock-warning-face nil t)
                                :source (my/org-calendar-view--read-only-source
                                         (point-marker) 'deadline)
                                :metadata (list :prepare-edit #'my/org-calendar-view--refuse-edit))
                               events))))))))))))
    (nreverse events)))

(defun my/org-calendar-view--google-minute (object)
  "Convert Google's OBJECT to local civil minutes, preserving all-day dates."
  (let* ((date (plist-get object :date))
         (time (and (not date) (parse-iso8601-time-string (plist-get object :dateTime))))
         (parts (mapcar #'string-to-number
                        (split-string (or date (format-time-string "%F" time)) "-")))
         (day (calendar-absolute-from-gregorian (list (nth 1 parts) (nth 2 parts) (car parts)))))
    (+ (* day 1440) (if date 0
                     (+ (* 60 (string-to-number (format-time-string "%H" time)))
                        (string-to-number (format-time-string "%M" time)))))))

(defun my/org-calendar-view--occurrences (start end)
  "Read-only Google occurrences from the cache, including pending scoped changes."
  (let (events)
    (when (and (fboundp 'my/org-calendar-repeat--effective-events)
               (equal my/org-calendar-auto--calendar my/org-calendar-id)
               (my/org-calendar-auto--same-file-p (my/org-file "calendar-personal.org")))
      (my/org-calendar-repeat--ensure-state)
      (dolist (event (my/org-calendar-repeat--effective-events))
        (unless (equal (plist-get event :status) "cancelled")
          (when-let* ((marker (my/org-calendar-repeat--series-marker (plist-get event :recurringEventId))))
            (unless (org-with-point-at marker (equal (org-get-todo-state) "CANCELLED"))
              (let ((from (my/org-calendar-view--google-minute (plist-get event :start)))
                    (to (my/org-calendar-view--google-minute (plist-get event :end))))
                (when (and (< from end) (> to start))
                  (push (org-timegrid-event-create
                         :id (list 'google (plist-get event :id))
                         :title (or (plist-get event :summary) "busy") :start from :end to
                         :all-day (and (plist-get (plist-get event :start) :date) t)
                         :color (face-foreground 'font-lock-string-face nil t)
                         :source (my/org-calendar-view--read-only-source
                                  marker 'occurrence (plist-get event :id))
                         :metadata (list :prepare-edit #'my/org-calendar-view--refuse-edit))
                        events))))))))
    (nreverse events)))

(defun my/org-calendar-view--list (start end)
  "List the central files and cached occurrences without network calls or saves.
Listing never changes a file."
  (let ((events (append (my/org-calendar-view--org-events start end)
                        (my/org-calendar-view--deadlines start end)
                        (my/org-calendar-view--occurrences start end))))
    (if (null my/org-calendar-view-profile) events
      (let ((files (mapcar #'my/org-file
                          (if (equal my/org-calendar-view-profile "work")
                              '("work.org" "calendar-work.org")
                            '("personal.org" "calendar-personal.org")))))
        (cl-remove-if-not
         (lambda (event)
           (let ((marker (plist-get (org-timegrid-event-source event) :heading-marker)))
             (member (buffer-file-name (marker-buffer marker)) files)))
         events)))))

(defun my/org-calendar-view-filter ()
  "Choose Work, Personal, or both, without changing source files."
  (interactive)
  (setq my/org-calendar-view-profile
        (pcase (completing-read "Week profile: " '("Both" "Work" "Personal") nil t)
          ("Work" "work") ("Personal" "personal") (_ nil)))
  (setq mode-name (format "Week (%s)" (or my/org-calendar-view-profile "both")))
  (org-timegrid--refresh-data))

(defun my/org-calendar-view--visit (event)
  "Visit EVENT's source; scoped Google edits remain in the normal agenda."
  (let* ((source (org-timegrid-event-source event))
         (marker (plist-get source :heading-marker)))
    (unless (and (markerp marker) (marker-buffer marker))
      (user-error "The source is no longer open; refresh the week view"))
    (pop-to-buffer (marker-buffer marker))
    (goto-char marker)
    (org-fold-show-context)
    (when (plist-get source :occurrence)
      (message "This is the shared series heading; use agenda , e for an occurrence edit"))))

;;; Editing

(defun my/org-calendar-view--personal-file-p (marker)
  "Non-nil when MARKER is in calendar-personal.org, whose saves sync to Google."
  (when-let* ((buffer (and (markerp marker) (marker-buffer marker)))
              (file (buffer-file-name buffer)))
    (file-equal-p file (my/org-file "calendar-personal.org"))))

(defun my/org-calendar-view--calendar-file-p (marker)
  "Non-nil when MARKER is in one of the two event files."
  (when-let* ((buffer (and (markerp marker) (marker-buffer marker)))
              (file (buffer-file-name buffer)))
    (cl-some (lambda (name) (file-equal-p file (my/org-file name)))
             '("calendar-work.org" "calendar-personal.org"))))

(defun my/org-calendar-view--timestamp-count (marker)
  "Count the active timestamps under the heading at MARKER; a range counts once."
  (org-with-point-at marker
    (org-with-wide-buffer
     (org-back-to-heading t)
     (save-restriction
       (narrow-to-region (point) (save-excursion (org-end-of-subtree t t) (point)))
       (let ((count 0))
         (org-element-map (org-element-parse-buffer) 'timestamp
           (lambda (timestamp)
             (when (memq (org-element-property :type timestamp) '(active active-range))
               (setq count (1+ count)))))
         count)))))

(defun my/org-calendar-view--check-editable (event)
  "Signal a `user-error' unless EVENT can be edited from the week.
Google occurrences and deadline markers are never editable.  An event in
calendar-personal.org syncs to Google, so recurring series, tasks, repeaters,
events with several timestamps and an unsaved buffer are refused."
  (let* ((source (org-timegrid-event-source event))
         (marker (plist-get source :marker))
         (metadata (org-timegrid-event-metadata event)))
    (pcase (plist-get source :read-only)
      ('occurrence (user-error "Repeating Google event: edit it in Google Calendar"))
      ('deadline (user-error "Deadline marker: change the deadline in the task")))
    (unless (and (markerp marker) (marker-buffer marker))
      (user-error "The source is no longer open; refresh the week view"))
    (when (plist-get metadata :repeater-type)
      (user-error "Repeating entry: change its repeater in the Org file"))
    (when (my/org-calendar-view--personal-file-p marker)
      (org-with-point-at marker
        (org-with-wide-buffer
         (org-back-to-heading t)
         (when (or (org-entry-get nil "GCAL_AUTO_RECURRING") (org-entry-get nil "recurrence"))
           (user-error "Repeating Google event: edit it in Google Calendar"))
         (when (org-get-todo-state)
           (user-error "Google events cannot have a TODO state; edit it in the Org file"))))
      (unless (= (my/org-calendar-view--timestamp-count marker) 1)
        (user-error "This event has more than one timestamp; edit it in the Org file"))
      (when (buffer-modified-p (marker-buffer marker))
        (user-error "Save calendar-personal.org first: saving it syncs to Google")))
    event))

(defun my/org-calendar-view--update (event start end &optional title time-kind)
  "Move, resize, retime or rename EVENT, saving its file."
  (my/org-calendar-view--check-editable event)
  (when-let* ((prefix (plist-get (org-timegrid-event-source event) :state-prefix))
              ((stringp title)))
    (setq title (string-remove-prefix (concat prefix " ") title)))
  (when (and title (string-empty-p (string-trim title)))
    (user-error "A title cannot be empty"))
  (my/org-calendar-view--with-settings t
    (org-timegrid-org--update-event-range event start end title time-kind)))

(defun my/org-calendar-view--cancel (event)
  "Cancel the Google event EVENT, which the sync then cancels on Google."
  (let ((marker (plist-get (org-timegrid-event-source event) :marker)))
    (unless (y-or-n-p (format "Cancel \"%s\" on Google Calendar too? "
                              (org-timegrid-event-title event)))
      (user-error "Event kept"))
    (with-current-buffer (marker-buffer marker)
      (org-with-wide-buffer
       (goto-char marker)
       (org-back-to-heading t)
       (undo-boundary)
       (atomic-change-group
         (let ((org-inhibit-logging t)) (org-todo "CANCELLED")))
       (undo-boundary))
      (org-timegrid-org--note-edit))
    (message "Cancelled %s" (org-timegrid-event-title event))))

(defun my/org-calendar-view--delete (event)
  "Remove EVENT's time; Google events are cancelled instead."
  (my/org-calendar-view--check-editable event)
  (if (my/org-calendar-view--personal-file-p (plist-get (org-timegrid-event-source event) :marker))
      (my/org-calendar-view--with-settings t (my/org-calendar-view--cancel event))
    (my/org-calendar-view--with-settings t (org-timegrid-org--remove-event event))))

(defun my/org-calendar-view--delete-entry (event)
  "Delete the whole heading of a local Work event."
  (my/org-calendar-view--check-editable event)
  (let ((marker (plist-get (org-timegrid-event-source event) :marker)))
    (unless (and (my/org-calendar-view--calendar-file-p marker)
                 (not (my/org-calendar-view--personal-file-p marker)))
      (user-error "Only local Work events can be deleted from the week"))
    (my/org-calendar-view--with-settings t (org-timegrid-org--remove-entry event))))

(defun my/org-calendar-view--entry-empty-p (event)
  "Offer to delete an emptied entry only for local Work events.
Tasks stay when unscheduled, and Google events are cancelled, not deleted."
  (let ((marker (plist-get (org-timegrid-event-source event) :marker)))
    (and (my/org-calendar-view--calendar-file-p marker)
         (not (my/org-calendar-view--personal-file-p marker))
         (org-timegrid-org--entry-empty-p event))))

(defun my/org-calendar-view--undo (continue redo)
  "Undo, or REDO, the last week edit; CONTINUE extends a run of them."
  (my/org-calendar-view--with-settings t
    (org-timegrid-org--undo continue redo)))

(defun my/org-calendar-view--transaction (function)
  "Run FUNCTION as one undo step that saves each touched file once."
  (my/org-calendar-view--with-settings t
    (org-timegrid-org--transaction function)))

;;; Creating

(defconst my/org-calendar-view--create-kinds
  '((personal-event
     "calendar-personal.org"
     (:target file :template "* %{title}\n:org-gcal:\n%{time-range}\n:END:\n%?"))
    (work-event
     "calendar-work.org"
     (:target file :template "* %{title}\n:org-gcal:\n%{time-range}\n:END:\n%?"))
    (work-task
     "work.org"
     (:target (headline "Inbox") :template "* TODO %{title}\nSCHEDULED: %{time-range}\n%?"))
    (personal-task
     "personal.org"
     (:target (headline "Inbox") :template "* TODO %{title}\nSCHEDULED: %{time-range}\n%?")))
  "Kind, file and capture template for each thing the week can create.")

(defun my/org-calendar-view--read-kind ()
  "Ask which kind to create with one key; return its symbol, or nil to cancel."
  (condition-case nil
      (pcase (car (read-multiple-choice
                   "New: "
                   '((?t "work task" "Work task, scheduled in work.org Inbox")
                     (?T "personal task" "Personal task, scheduled in personal.org Inbox")
                     (?e "work event" "Work event, local only")
                     (?E "personal event" "Personal event, synced to Google Calendar")
                     (?q "cancel" "Create nothing"))))
        (?t 'work-task) (?T 'personal-task) (?e 'work-event) (?E 'personal-event))
    (quit nil)))

(defun my/org-calendar-view--read-entry ()
  "Ask for the kind, then the title.  Return (TITLE . KIND); an empty title cancels."
  (if-let* ((kind (my/org-calendar-view--read-kind)))
      (cons (read-string "Title: ") kind)
    (cons "" nil)))

(defun my/org-calendar-view--create (title start end &optional source target time-kind)
  "Create TITLE from START to END as the kind in TARGET, asking when TARGET is nil.
Copies of existing entries are not supported."
  (when (or source (and target (not (symbolp target))))
    (user-error "Copying is not supported in the week; create a new entry"))
  (let* ((kind (or target (my/org-calendar-view--read-kind)))
         (spec (and kind (alist-get kind my/org-calendar-view--create-kinds)))
         (title (string-trim (replace-regexp-in-string
                              "%\\([?{<]\\)" "% \\1"
                              (replace-regexp-in-string "[\n\r]+" " " title)))))
    (cond
     ((null spec) (message "Nothing created"))
     ((string-empty-p title) (message "Nothing created"))
     (t
      (let ((file (my/org-file (car spec))))
        (when (and (eq kind 'personal-event)
                   (when-let* ((buffer (find-buffer-visiting file)))
                     (buffer-modified-p buffer)))
          (user-error "Save calendar-personal.org first: saving it syncs to Google"))
        (my/org-calendar-view--with-settings t
          (let ((org-timegrid-org-capture-file file)
                (org-timegrid-org-capture-template (cadr spec)))
            (org-timegrid-org--create-event title start end nil nil time-kind))))))))

;; `defconst', not `defvar': reloading this file must install the current
;; callbacks, or a running Emacs keeps a stale backend that refuses drags.
(defconst my/org-calendar-view--backend
  (org-timegrid-backend-create :name "Org week"
                              :list-function #'my/org-calendar-view--list
                              :visit-function #'my/org-calendar-view--visit
                              :create-function #'my/org-calendar-view--create
                              :update-function #'my/org-calendar-view--update
                              :delete-function #'my/org-calendar-view--delete
                              :delete-entry-function #'my/org-calendar-view--delete-entry
                              :undo-function #'my/org-calendar-view--undo
                              :transaction-function #'my/org-calendar-view--transaction
                              :entry-empty-function #'my/org-calendar-view--entry-empty-p
                              :entry-key-function #'org-timegrid-org--entry-key
                              :read-entry-function #'my/org-calendar-view--read-entry
                              :read-timestamp-function #'org-timegrid-org-read-timestamp)
  "Org week backend.  Google occurrences and deadline markers refuse every edit.")

(defun my/org-calendar-view-blocked ()
  "Explain where a blocked key's job belongs."
  (interactive)
  (user-error "Not available in the week: open the entry with RET to use Org commands"))

(defun my/org-calendar-view-no-copy ()
  "Explain that copy, cut and paste are not supported."
  (interactive)
  (user-error "Copy, cut and paste are not supported in the week: move with M-arrows, create with c"))

(defun my/org-calendar-view--task-command (command)
  "Return an interactive wrapper running Org COMMAND on the selected task, then saving.
Events are refused: Google events must not gain a TODO state or tags unseen."
  (lambda ()
    (interactive)
    (let* ((event (org-timegrid-block-event (org-timegrid--selected-block)))
           (source (and event (org-timegrid-event-source event))))
      (when (plist-get source :read-only)
        (my/org-calendar-view--check-editable event))
      (let ((marker (plist-get source :marker)))
        (unless (and (markerp marker) (marker-buffer marker)
                     (not (my/org-calendar-view--calendar-file-p marker)))
          (user-error "Org commands in the week apply to tasks; open an event with RET"))
        (let ((buffer (marker-buffer marker)))
          (org-timegrid-org--run-selected-command command)
          (with-current-buffer buffer
            (when (and buffer-file-name (buffer-modified-p)) (save-buffer))))))))

(defvar my/org-calendar-view-task-commands
  `((":" . ,(my/org-calendar-view--task-command #'org-set-tags-command))
    ("C-c C-q" . ,(my/org-calendar-view--task-command #'org-set-tags-command))
    ("C-c C-t" . ,(my/org-calendar-view--task-command #'org-todo))
    ("," . ,(my/org-calendar-view--task-command #'org-priority))
    ("C-c ," . ,(my/org-calendar-view--task-command #'org-priority))
    ("i" . ,(my/org-calendar-view--task-command #'org-clock-in))
    ("O" . ,(my/org-calendar-view--task-command #'org-clock-out))
    ("C-c C-x e" . ,(my/org-calendar-view--task-command #'org-set-effort)))
  "Org keys that act on a selected task and save its file.")

(defconst my/org-calendar-view--blocked-keys
  '("C-c C-w" "z" "C-c C-z")
  "Keys with no safe week version: refiling touches two buffers, notes open a window.")

(defconst my/org-calendar-view--no-copy-keys '("C-w" "C-y" "M-y" "M-w")
  "Cut, paste and copy: a pasted Google event could be duplicated with its sync identity.")

(defun my/org-calendar-view-refresh-visible (&rest _)
  "Refresh a visible SVG view after sync, without triggering another sync."
  (when-let* ((buffer (get-buffer my/org-calendar-view-buffer))
               ((get-buffer-window buffer t)))
    ;; A display failure must not turn a successful sync into an error.
    (condition-case err
        (with-current-buffer buffer (org-timegrid--refresh-data))
      (error (message "Week view could not refresh: %s" (error-message-string err))))))

(defun my/org-calendar-view-next-event (&optional count)
  "Select the next event, or say so when the week has none to move to."
  (interactive "p")
  (condition-case nil
      (if (< (or count 1) 0)
          (org-timegrid-previous-block)
        (org-timegrid-next-block))
    (wrong-type-argument (message "No event to move to"))))

(defun my/org-calendar-view-previous-event ()
  "Select the previous event, or say so when the week has none to move to."
  (interactive)
  (my/org-calendar-view-next-event -1))

(defconst my/org-calendar-view-key-groups
  '(("Move"
     ("j" org-timegrid-cursor-forward "15 minutes later")
     ("k" org-timegrid-cursor-backward "15 minutes earlier")
     ("h" org-timegrid-cursor-backward-day "previous day")
     ("l" org-timegrid-cursor-forward-day "next day")
     ("C-d" org-timegrid-cursor-page-down "page down")
     ("C-u" org-timegrid-cursor-page-up "page up")
     ("0" org-timegrid-cursor-day-start "start of the day")
     ("$" org-timegrid-cursor-day-end "end of the day"))
    ("Events"
     ("w" my/org-calendar-view-next-event "next event")
     ("b" my/org-calendar-view-previous-event "previous event")
     ("RET" org-timegrid-open-at-cursor "open the entry, or create on an empty slot")
     ("/" org-timegrid-isearch-forward "search event titles"))
    ("Edit"
     ("c" org-timegrid-create-at-cursor "create at the cursor")
     ("e" org-timegrid-edit-selected-title "rename")
     ("t" org-timegrid-retime-selected "change the time")
     ("d" org-timegrid-remove-selected "remove")
     ("J" org-timegrid-move-later "move 15 minutes later")
     ("K" org-timegrid-move-earlier "move 15 minutes earlier")
     ("<" org-timegrid-move-previous-day "move to the previous day")
     (">" org-timegrid-move-next-day "move to the next day")
     ("u" org-timegrid-undo "undo")
     ("C-r" org-timegrid-redo "redo"))
    ("Weeks"
     ("H" org-timegrid-previous-week "previous week")
     ("L" org-timegrid-next-week "next week")
     ("[" org-timegrid-previous-week "previous week")
     ("]" org-timegrid-next-week "next week")
     ("." org-timegrid-goto-today "this week")
     ("D" org-timegrid-goto-date "go to a date"))
    ("View"
     ("F" my/org-calendar-view-filter "show Work, Personal, or both")
     ("r" org-timegrid-refresh "reload")
     ("?" my/org-calendar-view-help "this help")
     ("q" quit-window "close")))
  "Keys of the week, grouped as `my/org-calendar-view-help' shows them.")

(defconst my/org-calendar-view-keys
  (mapcan (lambda (group)
            (mapcar (lambda (entry) (cons (nth 0 entry) (nth 1 entry))) (cdr group)))
          my/org-calendar-view-key-groups)
  "Key and command pairs bound in the week.")

(declare-function transient-setup "transient" (&optional name layout edit &rest params))

(defconst my/org-calendar-view--sticky-keys '("RET" "F" "?" "q" "D" "/" "c" "e" "t" "d")
  "Keys that close the menu; every other key keeps it open while you move.")

(defun my/org-calendar-view--menu-layout ()
  "Build the transient layout: one column per key group, side by side.
The titled group holds the columns directly; a group wrapped in another group
nests columns inside columns, which transient cannot draw."
  (apply #'vector
         :description "Week view · SPC n v"
          (mapcar (lambda (group)
                    (apply #'vector (car group)
                           (delq nil
                                 (mapcar (lambda (entry)
                                           (unless (equal (nth 0 entry) "?")
                                             (list (nth 0 entry) (nth 2 entry) (nth 1 entry)
                                                   :transient (not (member (nth 0 entry)
                                                                           my/org-calendar-view--sticky-keys)))))
                                         (cdr group)))))
                  my/org-calendar-view-key-groups)))

(defun my/org-calendar-view-help ()
  "Show the week view's keys as a which-key style menu; keys run from it too."
  (interactive)
  (require 'transient)
  (unless (get 'my/org-calendar-view-menu 'transient--layout)
    (eval `(transient-define-prefix my/org-calendar-view-menu ()
             "Week view keys."
             ,(my/org-calendar-view--menu-layout))
          t))
  (call-interactively #'my/org-calendar-view-menu))

;;;###autoload
(defun my/org-calendar-week ()
  "Open the editable graphical week using the central files and cached Google dates."
  (interactive)
  (unless (and (display-graphic-p) (image-type-available-p 'svg))
    (user-error "The graphical week needs SVG support; use Today or Review here"))
  (let ((org-timegrid-buffer-name my/org-calendar-view-buffer)
        (display-buffer-overriding-action
         '((display-buffer-same-window) (inhibit-same-window . nil))))
    (org-timegrid-open my/org-calendar-view--backend))
  (setq-local mode-name (format "Week (%s)" (or my/org-calendar-view-profile "both")))
  (use-local-map (copy-keymap org-timegrid-mode-map))
  ;; Task commands save their file; the rest have no safe week version.
  (pcase-dolist (`(,key . ,command) my/org-calendar-view-task-commands)
    (keymap-set (current-local-map) key command))
  (dolist (key my/org-calendar-view--blocked-keys)
    (keymap-set (current-local-map) key #'my/org-calendar-view-blocked))
  (dolist (key my/org-calendar-view--no-copy-keys)
    (keymap-set (current-local-map) key #'my/org-calendar-view-no-copy))
  ;; Vim-style keys. The view stays in Emacs state, so these single keys
  ;; reach the grid instead of evil; `?' lists them.
  (pcase-dolist (`(,key . ,command) my/org-calendar-view-keys)
    (keymap-set (current-local-map) key command))
  (when (fboundp 'evil-emacs-state) (evil-emacs-state))
  ;; Emacs's own cursor would box a whole hour slice of the image; the grid
  ;; draws its own cursor.
  (setq-local evil-emacs-state-cursor '(nil))
  (setq cursor-type nil)
  (when (fboundp 'my/org-calendar-auto--finish)
    (advice-add 'my/org-calendar-auto--finish :after #'my/org-calendar-view-refresh-visible))
  (message "Week: hjkl move, c create, e/t/d edit, u undo, RET opens, ? keys"))

(provide 'org-calendar-view)
