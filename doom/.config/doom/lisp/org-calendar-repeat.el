;;; org-calendar-repeat.el --- One Org heading per Google recurring series -*- lexical-binding: t; -*-
(require 'cl-lib)
(require 'org)
(require 'org-agenda)
(require 'json)
(require 'button)
(require 'seq)
(require 'subr-x)

(defvar my/org-calendar-auto-mode)
(defvar my/org-calendar-auto--file)
(defvar my/org-calendar-auto--calendar)
(defvar my/org-calendar-auto--local-table)
(defvar my/org-calendar-auto--remote-table)
(defvar my/org-calendar-auto--attention)
(defvar my/org-calendar-auto--rerun)
(defvar my/org-calendar-settings-file)
(defvar my/org-calendar-repeat--context nil)
(defvar my/org-calendar-repeat--events nil)
(defvar my/org-calendar-repeat--pending nil)
(defvar my/org-calendar-repeat--rendering nil)
(defvar my/org-calendar-repeat--last-backup nil)

(defun my/org-calendar-repeat--cache-file ()
  "Keep bounded occurrence data and queued edits outside Org and Git."
  (expand-file-name
   (concat "org-calendar-repeats-"
           (secure-hash 'sha256 (concat my/org-calendar-auto--calendar "\n"
                                       (file-truename my/org-calendar-auto--file))) ".json")
   (file-name-directory my/org-calendar-settings-file)))

(defun my/org-calendar-repeat--ensure-state ()
  "Load private state only for the currently pinned calendar/file pair."
  (let ((file (my/org-calendar-repeat--cache-file)))
    (unless (equal file my/org-calendar-repeat--context)
      (setq my/org-calendar-repeat--events nil my/org-calendar-repeat--pending nil)
      (when (file-exists-p file)
        (let ((data (with-temp-buffer
                      (insert-file-contents file)
                      (json-parse-buffer :object-type 'plist :array-type 'list :null-object nil))))
          (unless (and (eq (plist-get data :version) 1)
                       (equal (plist-get data :calendar) my/org-calendar-auto--calendar))
            (user-error "Recurring-event cache belongs to another calendar or version"))
          (setq my/org-calendar-repeat--events (plist-get data :events)
                my/org-calendar-repeat--pending (plist-get data :pending))))
      (setq my/org-calendar-repeat--context file))))

(defun my/org-calendar-repeat--save-state ()
  "Atomically save only calendar data, never OAuth credentials or tokens."
  (let* ((file (my/org-calendar-repeat--cache-file))
         (temporary (make-temp-file (concat file ".new-"))))
    (unwind-protect
        (progn
          (set-file-modes temporary #o600)
          (write-region
           (json-encode `((version . 1) (calendar . ,my/org-calendar-auto--calendar)
                          (events . ,(vconcat my/org-calendar-repeat--events))
                          (pending . ,(vconcat my/org-calendar-repeat--pending))))
           nil temporary nil 'silent)
          (rename-file temporary file t))
      (when (file-exists-p temporary) (delete-file temporary)))))

(defun my/org-calendar-repeat--lean-event (event)
  "Keep the fields needed for agenda display, identity, and conflict checks."
  (let (result)
    (dolist (key '(:id :etag :recurringEventId :originalStartTime :summary :start :end
                      :description :location :transparency :status))
      (when (plist-member event key)
        (setq result (plist-put result key (plist-get event key)))))
    result))

(defun my/org-calendar-repeat--series-marker (id)
  "Find the one stored series heading for ID, without touching its contents."
  (with-current-buffer (my/org-calendar-auto--buffer)
    (org-with-wide-buffer
     (car (delq nil
                (org-map-entries
                 (lambda ()
                   (when (and (org-entry-get nil "GCAL_AUTO_RECURRING")
                              (equal id (org-entry-get nil "GCAL_AUTO_ID")))
                     (point-marker))) nil 'file))))))

(defun my/org-calendar-repeat--clean-legacy-p (record)
  "Allow migration only for unchanged imported occurrences with no local notes."
  (let ((marker (plist-get record :marker)))
    (and (marker-buffer marker)
         (org-with-point-at marker
           (and (org-entry-get nil "GCAL_AUTO_SERIES")
                (not (org-get-todo-state)) (not (org-get-tags))
                (not (org-entry-get nil "GCAL_AUTO_CONFLICT"))
                (equal (plist-get record :base) (plist-get record :hash))
                (cl-every
                 (lambda (pair)
                   (or (and (equal (car pair) "CATEGORY")
                            (not (save-excursion
                                   (org-back-to-heading t)
                                   (re-search-forward "^[ \t]*:CATEGORY:" (save-excursion (outline-next-heading) (point)) t))))
                       (member (upcase (car pair)) '("CALENDAR-ID" "ENTRY-ID" "ETAG" "LOCATION" "TRANSPARENCY"
                                                    "GCAL_AUTO_ID" "GCAL_AUTO_BASE" "GCAL_AUTO_SERIES" "GCAL_AUTO_ERROR"))))
                 (org-entry-properties nil 'standard))
                (let* ((drawer (my/org-calendar-auto--drawer))
                       (body-start (save-excursion (org-end-of-meta-data) (point)))
                       (end (save-excursion (org-end-of-subtree t t) (point))))
                  (and drawer
                       (string-empty-p
                        (string-trim
                         (concat (buffer-substring-no-properties body-start (car drawer))
                                 (buffer-substring-no-properties (nth 1 drawer) end)))))))))))

(defun my/org-calendar-repeat--backup ()
  "Back up the saved calendar privately before merging any occurrence headings."
  (let ((backup (make-temp-file
                 (expand-file-name "org-calendar-before-series-"
                                   (file-name-directory my/org-calendar-settings-file)) nil ".org")))
    (copy-file my/org-calendar-auto--file backup t)
    (set-file-modes backup #o600)
    (setq my/org-calendar-repeat--last-backup backup)))

(defun my/org-calendar-repeat--migrate (records)
  "Merge clean legacy occurrences; preserve notes, conflicts, and unsent edits."
  (let ((groups (make-hash-table :test 'equal)) backed-up)
    (dolist (record records)
      (org-with-point-at (plist-get record :marker)
        (when-let* ((series (org-entry-get nil "GCAL_AUTO_SERIES")))
          (if (my/org-calendar-repeat--clean-legacy-p record)
              (push record (gethash series groups))
            (org-entry-put nil "GCAL_AUTO_ERROR"
                           "Occurrence retained: move its notes to the series or finish pending edits before merging")
            (setq my/org-calendar-auto--attention t)))))
    (maphash
     (lambda (series members)
       (when-let* ((master (gethash series my/org-calendar-auto--remote-table)))
         (when (and (plist-get master :recurrence) (not (equal (plist-get master :status) "cancelled")))
           (unless backed-up (my/org-calendar-repeat--backup) (setq backed-up t))
           (unless (my/org-calendar-repeat--series-marker series)
             (let ((record (pop members)))
               (org-with-point-at (plist-get record :marker)
                 (org-entry-delete nil "GCAL_AUTO_SERIES")
                 (org-entry-delete nil "GCAL_AUTO_ERROR")
                 (my/org-calendar-auto--import series master)
                 (puthash series (my/org-calendar-auto--record) my/org-calendar-auto--local-table))))
           (dolist (record (sort members (lambda (a b) (> (marker-position (plist-get a :marker))
                                                         (marker-position (plist-get b :marker))))))
             (org-with-point-at (plist-get record :marker)
               (delete-region (point) (save-excursion (org-end-of-subtree t t) (point)))))))) groups)
    (with-current-buffer (my/org-calendar-auto--buffer)
      (when (buffer-modified-p) (my/org-calendar-auto--save)))
    ;; Removed markers can slide onto another heading. Never reuse their old IDs.
    (seq-filter
     (lambda (record)
       (and (my/org-calendar-auto--safe-marker (plist-get record :marker))
            (org-with-point-at (plist-get record :marker)
              (equal (plist-get record :id) (org-entry-get nil "GCAL_AUTO_ID"))))) records)))

(defun my/org-calendar-repeat-prepare (records callback)
  "Replace expanded remote events by their series masters, then CALLBACK."
  (my/org-calendar-repeat--ensure-state)
  (let ((series (make-hash-table :test 'equal)) occurrences ids)
    (maphash
     (lambda (id event)
       (when-let* ((parent (plist-get event :recurringEventId)))
         (puthash parent t series)
         (push (my/org-calendar-repeat--lean-event event) occurrences)
         (push id ids))) my/org-calendar-auto--remote-table)
    (dolist (id ids) (remhash id my/org-calendar-auto--remote-table))
    (cl-labels
        ((step (remaining)
           (if remaining
               (let ((id (car remaining)))
                 (my/org-calendar-auto--request
                  "GET" id nil nil
                  (lambda (status event)
                    (cond ((eq status 200)
                           (puthash id event my/org-calendar-auto--remote-table)
                           (step (cdr remaining)))
                          ((memq status '(404 410))
                           (puthash id (list :id id :status "cancelled") my/org-calendar-auto--remote-table)
                           (step (cdr remaining)))
                          (t (my/org-calendar-auto--failure status))))))
             (if (buffer-modified-p (my/org-calendar-auto--buffer))
                 (my/org-calendar-auto--finish "pending")
               (let ((had-state (or my/org-calendar-repeat--events my/org-calendar-repeat--pending)))
                 (setq my/org-calendar-repeat--events (nreverse occurrences))
                 (when (or had-state occurrences) (my/org-calendar-repeat--save-state)))
               (funcall callback (my/org-calendar-repeat--migrate records))))))
      (step (hash-table-keys series)))))

(defun my/org-calendar-repeat--effective-events ()
  "Overlay saved occurrence edits; cancellations disappear while pending."
  (let ((events (copy-tree my/org-calendar-repeat--events)))
    (dolist (job my/org-calendar-repeat--pending)
      (setq events (seq-remove (lambda (event) (equal (plist-get event :id) (plist-get job :id))) events))
      (unless (equal (plist-get (plist-get job :desired) :status) "cancelled")
        (push (plist-get job :desired) events)))
    events))

(defun my/org-calendar-repeat--agenda (original file date &rest args)
  "Render Google's dated occurrences in memory, pointing to one series heading."
  (let ((ordinary (apply original file date args)))
    (if (or my/org-calendar-repeat--rendering
            (not (my/org-calendar-auto--same-file-p file)))
        ordinary
      (my/org-calendar-repeat--ensure-state)
      (setq ordinary
            (seq-remove
             (lambda (line)
               (when-let* ((marker (get-text-property 0 'org-hd-marker line)))
                 (org-with-point-at marker (org-entry-get nil "GCAL_AUTO_RECURRING")))) ordinary))
      (if (and args (not (memq :timestamp args))) ordinary
        (let ((source-buffer (my/org-calendar-auto--buffer))
              (source-map (make-hash-table :test 'equal))
              (legacy (make-hash-table :test 'equal))
              (render-map (make-hash-table :test 'equal))
              (my/org-calendar-repeat--rendering t) rendered)
          (with-current-buffer source-buffer
            (org-with-wide-buffer
             (org-map-entries
              (lambda ()
                (when (org-entry-get nil "GCAL_AUTO_RECURRING")
                  (unless (equal (org-get-todo-state) "CANCELLED")
                    (puthash (org-entry-get nil "GCAL_AUTO_ID") (point-marker) source-map)))
                (when (org-entry-get nil "GCAL_AUTO_SERIES")
                  (puthash (org-entry-get nil "GCAL_AUTO_ID") t legacy))) nil 'file)))
          (with-temp-buffer
            (insert "#+category: Personal\n")
            (dolist (event (my/org-calendar-repeat--effective-events))
              (when (and (not (equal (plist-get event :status) "cancelled"))
                         (gethash (plist-get event :recurringEventId) source-map)
                         (not (gethash (plist-get event :id) legacy)))
                (puthash (plist-get event :id) event render-map)
                (insert "\n* " (replace-regexp-in-string "[\r\n]+" " " (or (plist-get event :summary) "busy"))
                        "\n:PROPERTIES:\n:GCAL_RENDER_ID: " (plist-get event :id)
                        "\n:END:\n" (my/org-calendar-auto--timestamp event) "\n")))
            (let ((org-inhibit-startup t)) (delay-mode-hooks (org-mode)))
            (let ((render-buffer (current-buffer))
                  (buffer-file-name file)
                  (org-agenda-buffer source-buffer))
              (cl-letf (((symbol-function 'org-get-agenda-file-buffer) (lambda (&rest _) render-buffer)))
                (setq rendered (funcall original file date :timestamp))))
            (dolist (line rendered)
              (let* ((temporary-marker (get-text-property 0 'org-hd-marker line))
                     (id (org-with-point-at temporary-marker (org-entry-get nil "GCAL_RENDER_ID")))
                     (event (gethash id render-map))
                     (marker (gethash (plist-get event :recurringEventId) source-map)))
                (add-text-properties 0 (length line)
                                     (list 'org-hd-marker marker 'org-marker marker
                                           'my/org-calendar-repeat-id id
                                           'my/org-calendar-repeat-event event) line))))
          (append ordinary rendered))))))

(defun my/org-calendar-repeat--replace-job (job)
  (setq my/org-calendar-repeat--pending
        (cons job (seq-remove (lambda (old) (equal (plist-get old :id) (plist-get job :id)))
                              my/org-calendar-repeat--pending)))
  (my/org-calendar-repeat--save-state))

(defun my/org-calendar-repeat--drop-job (id)
  (setq my/org-calendar-repeat--pending
        (seq-remove (lambda (job) (equal id (plist-get job :id))) my/org-calendar-repeat--pending))
  (my/org-calendar-repeat--save-state))

(defun my/org-calendar-repeat--current-job (id)
  "Return the currently saved occurrence edit for ID."
  (seq-find (lambda (job) (equal id (plist-get job :id))) my/org-calendar-repeat--pending))

(defun my/org-calendar-repeat--complete-job (job result)
  "Acknowledge JOB without losing a newer edit saved during its HTTP request."
  (let* ((id (plist-get job :id)) (current (my/org-calendar-repeat--current-job id)))
    (if (equal current job)
        (my/org-calendar-repeat--drop-job id)
      (when current
        (when result
          (my/org-calendar-repeat--replace-job (plist-put (copy-tree current) :base result)))
        (setq my/org-calendar-auto--rerun t)))))

(defun my/org-calendar-repeat--queue (event desired)
  "Persist a change to exactly EVENT's occurrence, without changing its series."
  (my/org-calendar-repeat--ensure-state)
  (let* ((id (plist-get event :id))
         (old (seq-find (lambda (job) (equal id (plist-get job :id))) my/org-calendar-repeat--pending)))
    (my/org-calendar-repeat--replace-job
     (list :id id :base (or (plist-get old :base) event) :desired desired)))
  (my/org-calendar-auto--status "pending")
  (my/org-calendar-auto--schedule))

(defun my/org-calendar-repeat--conflict (job latest)
  (my/org-calendar-repeat--replace-job
   (plist-put (plist-put job :conflict (or latest (list :id (plist-get job :id) :status "cancelled")))
              :resolution nil))
  (setq my/org-calendar-auto--attention t))

(defun my/org-calendar-repeat-process-pending (next)
  "Reconcile saved per-occurrence edits with ETags before continuing with NEXT."
  (cl-labels
      ((step (jobs)
         (if (null jobs) (funcall next)
           (let* ((job (car jobs)) (id (plist-get job :id)) (desired (plist-get job :desired))
                  (cancelled (equal (plist-get desired :status) "cancelled")))
             (my/org-calendar-auto--request
              "GET" id nil nil
              (lambda (status latest)
                (cond
                 ((not (equal job (my/org-calendar-repeat--current-job id)))
                  (setq my/org-calendar-auto--rerun t) (step (cdr jobs)))
                 ((not (memq status '(200 404 410))) (my/org-calendar-auto--failure status))
                 ((or (and cancelled (or (memq status '(404 410))
                                          (equal (plist-get latest :status) "cancelled")))
                      (and (eq status 200)
                           (equal (my/org-calendar-auto--remote-payload latest)
                                  (my/org-calendar-auto--remote-payload desired))))
                  (my/org-calendar-repeat--complete-job job latest) (step (cdr jobs)))
                 ((or (not (eq status 200)) (equal (plist-get latest :status) "cancelled")
                      (if (plist-get job :resolution)
                          (not (equal (plist-get latest :etag) (plist-get (plist-get job :conflict) :etag)))
                        (or (plist-get job :conflict)
                            (not (equal (plist-get latest :etag) (plist-get (plist-get job :base) :etag))))))
                  (my/org-calendar-repeat--conflict job latest) (step (cdr jobs)))
                 (t
                  (my/org-calendar-auto--request
                   (if cancelled "DELETE" "PATCH") id
                   (unless cancelled (my/org-calendar-auto--remote-payload desired))
                   (plist-get latest :etag)
                   (lambda (code result)
                     (cond
                      ((or (and code (<= 200 code) (< code 300))
                           (and cancelled (memq code '(404 410))))
                       (my/org-calendar-repeat--complete-job job
                                                             (if cancelled (list :id id :status "cancelled") result))
                       (setq my/org-calendar-repeat--events
                             (seq-remove (lambda (event) (equal id (plist-get event :id)))
                                         my/org-calendar-repeat--events))
                       (unless cancelled (push (my/org-calendar-repeat--lean-event result) my/org-calendar-repeat--events))
                       (my/org-calendar-repeat--save-state)
                       (step (cdr jobs)))
                      ((eq code 412)
                       (my/org-calendar-auto--request
                        "GET" id nil nil
                        (lambda (read-status fresh)
                          (cond
                           ((not (memq read-status '(200 404 410))) (my/org-calendar-auto--failure read-status))
                           (t
                            (when (equal job (my/org-calendar-repeat--current-job id))
                              (my/org-calendar-repeat--conflict job fresh))
                            (step (cdr jobs)))))))
                      (t (my/org-calendar-auto--failure code))))
                   '((sendUpdates . "none")))))))))))
    (step (copy-tree my/org-calendar-repeat--pending))))

(defun my/org-calendar-repeat--selected ()
  "Return the generated occurrence selected in the agenda, if any."
  (when (derived-mode-p 'org-agenda-mode)
    (org-get-at-bol 'my/org-calendar-repeat-event)))

(defun my/org-calendar-repeat--approve-series (marker)
  "Approve the current saved series version, never newer edits or conflicts."
  (unless (my/org-calendar-auto--safe-marker marker) (user-error "Save the series first"))
  (org-with-point-at marker
    (unless (yes-or-no-p "Apply these changes to the entire recurring series in Google? ") (user-error "Not approved"))
    (org-entry-put nil "GCAL_SERIES_APPROVED"
                   (my/org-calendar-auto--hash (my/org-calendar-auto--local-payload)))
    (org-entry-delete nil "GCAL_AUTO_ERROR")
    (save-buffer))
  (my/org-calendar-auto--schedule))

(defun my/org-calendar-repeat--todo (original &rest arguments)
  "Make cancellation scope explicit for generated recurring agenda rows."
  (if-let* ((event (my/org-calendar-repeat--selected)))
      (pcase (completing-read "Recurring event (Google + agenda): "
                              '("Keep event" "Delete this occurrence" "Delete entire series")
                              nil t nil nil "Keep event")
        ("Delete this occurrence"
         (let* ((start (plist-get event :start))
                (date (or (plist-get start :date)
                          (format-time-string "%Y-%m-%d %H:%M"
                                              (parse-iso8601-time-string (plist-get start :dateTime))))))
           (when (yes-or-no-p
                  (format "Delete only \"%s\" on %s from Google and the agenda? Other occurrences stay unchanged. "
                          (or (plist-get event :summary) "busy") date))
             (my/org-calendar-repeat--queue event (plist-put (copy-tree event) :status "cancelled"))
             (message "Deletion queued for this occurrence only"))))
        ("Delete entire series"
         (unless (my/org-calendar-auto--safe-marker (org-get-at-bol 'org-hd-marker))
            (user-error "Save the calendar buffer before cancelling the series"))
          (when (yes-or-no-p
                 (format "Delete ALL occurrences of \"%s\" from Google and the agenda? "
                         (or (plist-get event :summary) "busy")))
            (org-with-point-at (org-get-at-bol 'org-hd-marker)
             (let ((org-inhibit-logging t)) (org-todo "CANCELLED"))
             (org-entry-put nil "GCAL_SERIES_APPROVED"
                            (my/org-calendar-auto--hash (my/org-calendar-auto--local-payload)))
              (save-buffer))
            (message "Deletion queued for the entire recurring series"))))
    (apply original arguments)))

(defun my/org-calendar-repeat-edit ()
  "Choose occurrence or series scope before editing a recurring agenda event."
  (interactive)
  (if-let* ((event (my/org-calendar-repeat--selected)))
      (if (equal (completing-read "Edit: " '("This occurrence" "Entire series") nil t nil nil "This occurrence")
                 "Entire series")
          (progn (org-agenda-switch-to) (message "Editing the series; save, then approve changes in SPC n g s"))
        (let ((base (copy-tree event)) (buffer (generate-new-buffer "*Recurring Occurrence Edit*")))
          (with-current-buffer buffer
            (insert "* " (or (plist-get event :summary) "busy") "\n")
            (org-mode)
            (my/org-calendar-auto--import (plist-get event :id) event)
            (setq-local header-line-format "This occurrence only: C-c C-c saves; C-c C-k aborts")
            (use-local-map (copy-keymap (current-local-map)))
            (local-set-key (kbd "C-c C-k") (lambda () (interactive) (kill-buffer (current-buffer))))
            (local-set-key
             (kbd "C-c C-c")
             (lambda ()
               (interactive)
               (goto-char (point-min))
               (let* ((payload (my/org-calendar-auto--local-payload))
                      (fields (json-parse-string (json-encode payload) :object-type 'plist :array-type 'list))
                      (desired (copy-tree base)))
                 (while fields (setq desired (plist-put desired (pop fields) (pop fields))))
                 (my/org-calendar-repeat--queue base desired))
               (kill-buffer (current-buffer)))))
          (pop-to-buffer buffer)))
    (org-agenda-switch-to)))

(defun my/org-calendar-repeat--guard-date (original &rest arguments)
  "Don't let generic date/deadline commands silently edit a series anchor."
  (if (my/org-calendar-repeat--selected)
      (user-error "Recurring event: use , e to choose this occurrence or the entire series")
    (apply original arguments)))

(defun my/org-calendar-repeat-review ()
  "Append series approval and per-occurrence conflict controls to sync status."
  (let (approvals)
    (with-current-buffer (my/org-calendar-auto--buffer)
      (org-with-wide-buffer
       (org-map-entries
        (lambda ()
          (when (and (org-entry-get nil "GCAL_AUTO_RECURRING")
                     (equal (org-entry-get nil "GCAL_AUTO_ERROR") "Series changes need approval in SPC n g s"))
            (push (cons (org-get-heading t t t t) (point-marker)) approvals))) nil 'file)))
    (dolist (approval approvals)
      (let ((marker (cdr approval)))
        (insert "\nSeries changes: " (car approval) "\n")
        (insert-text-button "Approve entire series" 'follow-link t
                            'action (lambda (_) (my/org-calendar-repeat--approve-series marker)))
        (insert "\n")))
    (dolist (job my/org-calendar-repeat--pending)
      (when (plist-get job :conflict)
        (let ((id (plist-get job :id)) (snapshot (copy-tree job)))
          (insert "\nOccurrence conflict: " (or (plist-get (plist-get job :desired) :summary) "event")
                  "\n")
          (my/org-calendar-auto--insert-comparison (plist-get job :desired) (plist-get job :conflict)
                                                   "This occurrence only")
          (unless (equal (plist-get (plist-get job :conflict) :status) "cancelled")
            (my/org-calendar-auto--insert-choice
             "Keep Org occurrence" (lambda (_)
                                     (let ((current (my/org-calendar-repeat--current-job id)))
                                       (unless (equal snapshot current)
                                         (user-error "Occurrence changed; reopen SPC n g s before choosing"))
                                       (my/org-calendar-repeat--replace-job (plist-put (copy-tree current) :resolution "org"))
                                       (my/org-calendar-auto--schedule)))
             (if (equal (plist-get (plist-get job :desired) :status) "cancelled")
                 "Delete only this occurrence from Google; leave the series unchanged."
               "Update only this occurrence on Google; leave the series unchanged.")))
          (my/org-calendar-auto--insert-choice
           (if (equal (plist-get (plist-get job :conflict) :status) "cancelled")
               "Accept Google deletion" "Use Google occurrence")
           (lambda (_)
             (unless (equal snapshot (my/org-calendar-repeat--current-job id))
               (user-error "Occurrence changed; reopen SPC n g s before choosing"))
             (my/org-calendar-repeat--drop-job id)
             (my/org-calendar-auto--schedule))
           "Discard this occurrence's pending Org edit and use Google; leave the series unchanged."))))))

(advice-add 'org-agenda-get-day-entries :around #'my/org-calendar-repeat--agenda)
(advice-add 'org-agenda-todo :around #'my/org-calendar-repeat--todo)
(dolist (command '(org-agenda-date-prompt org-agenda-do-date-earlier org-agenda-do-date-later
                   org-agenda-date-earlier org-agenda-date-later
                   org-agenda-schedule org-agenda-deadline org-agenda-kill
                   org-agenda-drag-line-forward org-agenda-drag-line-backward
                   org-agenda-archive-with org-agenda-refile org-agenda-bulk-mark))
  (advice-add command :around #'my/org-calendar-repeat--guard-date))

(provide 'org-calendar-repeat)
