;;; org-calendar-view-test.el -*- lexical-binding: t; -*-
;; Run with org-timegrid and the normal calendar-test dependencies on load-path.
(unless (featurep 'org-calendar-auto)
  (load (expand-file-name "org-calendar-auto-test.el" (file-name-directory load-file-name)) nil t))
(load (expand-file-name "../lisp/org-calendar-view.el" (file-name-directory load-file-name)) nil t)

;; The workspace runs timers at once, which would add undo boundaries mid-edit.
(defconst my/calendar-view-test-real-run-at-time (symbol-function 'run-at-time))

(defun my/calendar-view-test-range ()
  (let ((day (calendar-absolute-from-gregorian '(10 12 2026))))
    (list (* day 1440) (* (+ day 7) 1440))))

(defun my/calendar-view-test-minute (day hour minute)
  "Absolute minute for October DAY 2026 at HOUR:MINUTE."
  (+ (* (calendar-absolute-from-gregorian (list 10 day 2026)) 1440) (* hour 60) minute))

(defun my/calendar-view-test-event (events title)
  (or (seq-find (lambda (event) (equal (org-timegrid-event-title event) title)) events)
      (ert-fail (format "No event %S in %S" title (mapcar #'org-timegrid-event-title events)))))

(defun my/calendar-view-file-text (name)
  "Saved contents of the central file NAME."
  (with-temp-buffer (insert-file-contents (my/org-file name)) (buffer-string)))

(ert-deftest my/calendar-view-shows-scheduled-tasks-and-deadlines-without-making-appointments ()
  (my/calendar-test-workspace
    (my/org-test-append "work.org"
                        "\n* DOING Scheduled work\nSCHEDULED: <2026-10-12 Mon 09:00-10:00> DEADLINE: <2026-10-14 Wed 17:00>\n* TODO Undated task\n* DONE Finished\nSCHEDULED: <2026-10-12 Mon 12:00>\n* Note\n<2026-10-12 Mon 13:00>\n")
    (my/org-test-append "personal.org"
                        "\n* WAIT Date-only plan\nSCHEDULED: <2026-10-13 Tue>\n")
    (let* ((events (apply #'my/org-calendar-view--list (my/calendar-view-test-range)))
           (titles (mapcar #'org-timegrid-event-title events))
           (deadline (seq-find (lambda (event) (string-prefix-p "Due" (org-timegrid-event-title event))) events)))
      (should (equal (sort titles #'string<)
                     '("DOING Scheduled work" "Due 17:00: Scheduled work" "WAIT Date-only plan")))
      (should (org-timegrid-event-all-day deadline))
      (should (= (- (org-timegrid-event-end deadline) (org-timegrid-event-start deadline)) 1440))
      (should-not my/calendar-test-calls))))

(ert-deftest my/calendar-view-reads-only-central-files-and-never-saves-unsaved-edits ()
  (my/calendar-test-workspace
    (my/org-test-append "calendar-work.org"
                        "\n* Local event\n:org-gcal:\n<2026-10-12 Mon 10:00-11:00>\n:END:\n")
    (my/org-test-append "reference.org" "\n* Must not display\n<2026-10-12 Mon 12:00>\n")
    (push (my/org-file "reference.org") org-agenda-files)
    (with-current-buffer (find-file-noselect (my/org-file "personal.org"))
      (goto-char (point-max))
      (insert "\n* TODO Unsaved plan\nSCHEDULED: <2026-10-12 Mon 14:00>\n")
      (let ((text (buffer-string)) (position (point)))
        (cl-letf (((symbol-function 'save-buffer) (lambda (&rest _) (ert-fail "View must not save")))
                  ((symbol-function 'my/org-calendar-auto--request)
                   (lambda (&rest _) (ert-fail "View must not contact Google"))))
          (let ((events (apply #'my/org-calendar-view--list (my/calendar-view-test-range))))
            (should (= (length events) 2))
            (should-not (seq-some (lambda (event) (equal (org-timegrid-event-title event) "Must not display")) events))))
        (should (equal text (buffer-string)))
        (should (= position (point)))
        (should (buffer-modified-p))))))

(ert-deftest my/calendar-view-keeps-local-org-repeaters-without-generating-source-headings ()
  (my/calendar-test-workspace
    (my/org-test-append "calendar-work.org"
                        "\n* Local daily event\n<2026-10-12 Mon 10:00-11:00 +1d>\n")
    (with-current-buffer (find-file-noselect (my/org-file "calendar-work.org"))
      (let ((text (buffer-string)))
        (should (= (length (apply #'my/org-calendar-view--list (my/calendar-view-test-range))) 7))
        (should (equal text (buffer-string)))
        (should-not (buffer-modified-p))))))

(ert-deftest my/calendar-view-google-times-use-local-time-and-all-day-dates-stay-civil ()
  (let ((old-zone (getenv "TZ"))
        (day (calendar-absolute-from-gregorian '(10 12 2026))))
    (unwind-protect
        (progn
          (set-time-zone-rule "America/Sao_Paulo")
          (should (= (my/org-calendar-view--google-minute '(:dateTime "2026-10-12T18:00:00+01:00"))
                     (+ (* day 1440) (* 14 60))))
          (should (= (my/org-calendar-view--google-minute '(:date "2026-10-12")) (* day 1440))))
      (set-time-zone-rule old-zone))))

(ert-deftest my/calendar-view-google-occurrences-use-cache-not-series-anchors ()
  (my/calendar-test-workspace
    (my/org-test-append "calendar-personal.org"
                        "\n* Shared series\n:PROPERTIES:\n:GCAL_AUTO_ID: series-id\n:GCAL_AUTO_RECURRING: t\n:END:\n:org-gcal:\n<2026-10-12 Mon 10:00-11:00>\n:END:\n")
    (my/org-calendar-repeat--ensure-state)
    (setq my/org-calendar-repeat--events
          '((:id "occurrence-1" :recurringEventId "series-id" :summary "First date"
             :start (:date "2026-10-12") :end (:date "2026-10-13"))
            (:id "occurrence-2" :recurringEventId "series-id" :summary "Second date"
             :start (:date "2026-10-14") :end (:date "2026-10-15"))))
    (let* ((events (apply #'my/org-calendar-view--list (my/calendar-view-test-range)))
           (sources (mapcar #'org-timegrid-event-source events)))
      (should (equal (mapcar #'org-timegrid-event-title events) '("First date" "Second date")))
      (should (equal (plist-get (car sources) :heading-marker)
                     (plist-get (cadr sources) :heading-marker)))
      (dolist (source sources)
        (should (markerp (plist-get source :heading-marker)))
        (should (plist-get source :occurrence))
        (should-not (plist-get source :marker)))
      (should-not my/calendar-test-calls))))

(ert-deftest my/calendar-view-overlays-pending-occurrence-edits-and-cancellations ()
  (my/calendar-test-workspace
    (my/org-test-append "calendar-personal.org"
                        "\n* Series\n:PROPERTIES:\n:GCAL_AUTO_ID: series-id\n:GCAL_AUTO_RECURRING: t\n:END:\n")
    (my/org-calendar-repeat--ensure-state)
    (setq my/org-calendar-repeat--events
          '((:id "one" :recurringEventId "series-id" :summary "Old title"
             :start (:date "2026-10-12") :end (:date "2026-10-13"))))
    (setq my/org-calendar-repeat--pending
          '((:id "one" :desired (:id "one" :recurringEventId "series-id" :summary "Pending title"
                                        :start (:date "2026-10-14") :end (:date "2026-10-15")))))
    (should (equal (mapcar #'org-timegrid-event-title
                          (apply #'my/org-calendar-view--list (my/calendar-view-test-range)))
                   '("Pending title")))
    (setq my/org-calendar-repeat--pending '((:id "one" :desired (:status "cancelled"))))
    (should-not (apply #'my/org-calendar-view--list (my/calendar-view-test-range)))))

(ert-deftest my/calendar-view-backend-edits-org-and-marks-synthetic-entries-read-only ()
  (dolist (getter '(org-timegrid-backend-create-function org-timegrid-backend-update-function
                   org-timegrid-backend-delete-function org-timegrid-backend-delete-entry-function
                   org-timegrid-backend-undo-function org-timegrid-backend-transaction-function))
    (should (functionp (funcall getter my/org-calendar-view--backend))))
  (my/calendar-test-workspace
    (my/org-test-append "work.org" "\n* TODO Task\nSCHEDULED: <2026-10-12 Mon 10:00> DEADLINE: <2026-10-13 Tue>\n")
    (my/org-test-append "calendar-personal.org"
                        "\n* Series\n:PROPERTIES:\n:GCAL_AUTO_ID: series-id\n:GCAL_AUTO_RECURRING: t\n:END:\n")
    (my/org-calendar-repeat--ensure-state)
    (setq my/org-calendar-repeat--events
          '((:id "one" :recurringEventId "series-id" :summary "Repeat"
             :start (:date "2026-10-12") :end (:date "2026-10-13"))))
    (let* ((events (apply #'my/org-calendar-view--list (my/calendar-view-test-range)))
           (task (my/calendar-view-test-event events "TODO Task"))
           (deadline (my/calendar-view-test-event events "Due: Task"))
           (occurrence (my/calendar-view-test-event events "Repeat")))
      (should (markerp (plist-get (org-timegrid-event-source task) :marker)))
      (should (markerp (plist-get (org-timegrid-event-source task) :heading-marker)))
      (should-not (plist-get (org-timegrid-event-source task) :read-only))
      (should (eq (plist-get (org-timegrid-event-source deadline) :read-only) 'deadline))
      (should (eq (plist-get (org-timegrid-event-source occurrence) :read-only) 'occurrence))
      (dolist (event (list deadline occurrence))
        (should-not (plist-get (org-timegrid-event-source event) :marker))))))

(ert-deftest my/calendar-view-occurrences-and-deadline-markers-refuse-every-edit ()
  (my/calendar-test-workspace
    (my/org-test-append "work.org" "\n* TODO Task\nSCHEDULED: <2026-10-12 Mon 10:00> DEADLINE: <2026-10-13 Tue>\n")
    (my/org-test-append "calendar-personal.org"
                        "\n* Series\n:PROPERTIES:\n:GCAL_AUTO_ID: series-id\n:GCAL_AUTO_RECURRING: t\n:END:\n")
    (my/org-calendar-repeat--ensure-state)
    (setq my/org-calendar-repeat--events
          '((:id "one" :recurringEventId "series-id" :summary "Repeat"
             :start (:date "2026-10-12") :end (:date "2026-10-13"))))
    (let* ((events (apply #'my/org-calendar-view--list (my/calendar-view-test-range)))
           (deadline (my/calendar-view-test-event events "Due: Task"))
           (occurrence (my/calendar-view-test-event events "Repeat"))
           (work (my/calendar-view-file-text "work.org"))
           (personal (my/calendar-view-file-text "calendar-personal.org")))
      (dolist (case `((,deadline . "Deadline marker: change the deadline in the task")
                      (,occurrence . "Repeating Google event: edit it in Google Calendar")))
        (let ((event (car case)) (message (cdr case)))
          (dolist (call (list (lambda () (my/org-calendar-view--update event 1440 2880 nil 'all-day))
                              (lambda () (my/org-calendar-view--update event 1440 2880 "Renamed" 'all-day))
                              (lambda () (my/org-calendar-view--delete event))
                              (lambda () (my/org-calendar-view--delete-entry event))
                              (lambda () (funcall (plist-get (org-timegrid-event-metadata event) :prepare-edit)
                                                  event))))
            (should (equal (cadr (should-error (funcall call) :type 'user-error)) message)))))
      (should (equal work (my/calendar-view-file-text "work.org")))
      (should (equal personal (my/calendar-view-file-text "calendar-personal.org"))))))

(ert-deftest my/calendar-view-creates-each-kind-in-its-file-and-sync-ready-shape ()
  (my/calendar-test-workspace
    (let ((start (my/calendar-view-test-minute 14 10 0))
          (end (my/calendar-view-test-minute 14 11 0))
          (org-timegrid-org--undo-transactions nil)
          (org-timegrid-org--redo-transactions nil))
      (dolist (case '((?e "personal event" "calendar-personal.org"
                          "* Dentist\n:org-gcal:\n<2026-10-14 Wed 10:00-11:00>\n:END:\n")
                      (?w "work event" "calendar-work.org"
                          "* Dentist\n:org-gcal:\n<2026-10-14 Wed 10:00-11:00>\n:END:\n")
                      (?t "work task" "work.org"
                          "** TODO Dentist\nSCHEDULED: <2026-10-14 Wed 10:00-11:00>\n")
                      (?p "personal task" "personal.org"
                          "** TODO Dentist\nSCHEDULED: <2026-10-14 Wed 10:00-11:00>\n")))
        (pcase-let ((`(,key ,name ,file ,shape) case))
          (cl-letf (((symbol-function 'read-multiple-choice) (lambda (&rest _) (list key name)))
                    ((symbol-function 'read-string) (lambda (&rest _) "Dentist")))
            (pcase-let ((`(,title . ,kind) (my/org-calendar-view--read-entry)))
              (should (equal title "Dentist"))
              (my/org-calendar-view--create title start end nil kind 'timed)))
          (should (string-match-p (regexp-quote shape) (my/calendar-view-file-text file)))
          (should-not (buffer-modified-p (find-buffer-visiting (my/org-file file))))))
      (let ((text (my/calendar-view-file-text "work.org")))
        (should (< (string-match "\\* Inbox" text) (string-match "TODO Dentist" text)
                   (string-match "\\* Tasks" text))))
      (let ((events (apply #'my/org-calendar-view--list (my/calendar-view-test-range))))
        (should (equal (sort (mapcar #'org-timegrid-event-title events) #'string<)
                       '("Dentist" "Dentist" "TODO Dentist" "TODO Dentist")))
        (dolist (event events)
          (should (= (org-timegrid-event-start event) start))
          (should (= (org-timegrid-event-end event) end))))
      (with-current-buffer (find-buffer-visiting (my/org-file "calendar-personal.org"))
        (goto-char (point-min))
        (org-next-visible-heading 1)
        (let ((payload (my/org-calendar-auto--local-payload)))
          (should (equal (alist-get 'summary payload) "Dentist"))
          (should (equal (alist-get 'status payload) "confirmed"))
          (should-not (org-entry-get nil "GCAL_AUTO_ID"))
          (should-not (org-entry-get nil "entry-id")))))))

(ert-deftest my/calendar-view-creates-all-day-entries-with-dates-only ()
  (my/calendar-test-workspace
    (let ((start (my/calendar-view-test-minute 14 0 0))
          (end (my/calendar-view-test-minute 15 0 0)))
      (dolist (kind '(personal-event work-task))
        (my/org-calendar-view--create "Holiday" start end nil kind 'all-day))
      (should (string-match-p "^:org-gcal:\n<2026-10-14 Wed>\n:END:"
                              (my/calendar-view-file-text "calendar-personal.org")))
      (should (string-match-p "^SCHEDULED: <2026-10-14 Wed>$"
                              (my/calendar-view-file-text "work.org")))
      (should (= (length (seq-filter #'org-timegrid-event-all-day
                                     (apply #'my/org-calendar-view--list (my/calendar-view-test-range))))
                 2)))))

(ert-deftest my/calendar-view-cancelled-creation-leaves-everything-untouched ()
  (my/calendar-test-workspace
    (let ((before (mapcar #'my/calendar-view-file-text
                          '("work.org" "personal.org" "calendar-work.org" "calendar-personal.org")))
          (start (my/calendar-view-test-minute 14 10 0))
          (end (my/calendar-view-test-minute 14 11 0)))
      (dolist (choice (list (lambda (&rest _) (list ?q "cancel"))
                            (lambda (&rest _) (signal 'quit nil))))
        (cl-letf (((symbol-function 'read-multiple-choice) choice)
                  ((symbol-function 'read-string) (lambda (&rest _) (ert-fail "No title prompt"))))
          (should (equal (my/org-calendar-view--read-entry) '("" . nil)))
          (my/org-calendar-view--create "Nothing" start end nil nil 'timed)))
      (should (equal before (mapcar #'my/calendar-view-file-text
                                    '("work.org" "personal.org" "calendar-work.org" "calendar-personal.org"))))
      (should-error (my/org-calendar-view--create "Copy" start end (org-timegrid-event-create) nil 'timed)
                    :type 'user-error)
      (should-error (my/org-calendar-view--create "Copy" start end nil '(:marker nil) 'timed)
                    :type 'user-error))))

(ert-deftest my/calendar-view-move-and-resize-rewrite-the-only-drawer-timestamp ()
  (my/calendar-test-workspace
    (my/org-test-append "calendar-personal.org"
                        (concat "\n* Single\n:org-gcal:\n<2026-10-13 Tue 10:00-11:00>\n:END:\n"
                                "\n* Pair\n:org-gcal:\n<2026-10-14 Wed 14:00>--<2026-10-14 Wed 15:00>\n:END:\n"))
    (let* ((events (apply #'my/org-calendar-view--list (my/calendar-view-test-range)))
           (single (my/calendar-view-test-event events "Single"))
           (pair (my/calendar-view-test-event events "Pair")))
      (my/org-calendar-view--update single (+ (org-timegrid-event-start single) 60)
                                    (+ (org-timegrid-event-end single) 120) nil 'timed)
      (my/org-calendar-view--update pair (+ (org-timegrid-event-start pair) 1440)
                                    (+ (org-timegrid-event-end pair) 1440) nil 'timed)
      (let ((text (my/calendar-view-file-text "calendar-personal.org")))
        (should (string-match-p (regexp-quote "<2026-10-13 Tue 11:00-13:00>") text))
        (should (string-match-p (regexp-quote "<2026-10-15 Thu 14:00-15:00>") text))
        (should-not (string-match-p "10:00-11:00\\|2026-10-14" text))
        (should (= (length (split-string text "<20")) 3)))
      (my/org-calendar-view--update single (org-timegrid-event-start single)
                                    (org-timegrid-event-end single) "Renamed" 'timed)
      (should (string-match-p "^\\* Renamed$" (my/calendar-view-file-text "calendar-personal.org")))
      (should-not (buffer-modified-p (find-buffer-visiting (my/org-file "calendar-personal.org")))))))

(ert-deftest my/calendar-view-refuses-unsafe-google-event-edits ()
  (my/calendar-test-workspace
    (my/org-test-append "calendar-personal.org"
                        "\n* Event\n:org-gcal:\n<2026-10-13 Tue 10:00-11:00>\n:END:\n")
    (let* ((event (car (apply #'my/org-calendar-view--list (my/calendar-view-test-range))))
           (buffer (find-buffer-visiting (my/org-file "calendar-personal.org")))
           (original (my/calendar-view-file-text "calendar-personal.org")))
      (dolist (change `(("GCAL_AUTO_RECURRING" . "t") ("recurrence" . "[\"RRULE:FREQ=DAILY\"]")))
        (with-current-buffer buffer
          (goto-char (point-min)) (org-next-visible-heading 1)
          (org-entry-put nil (car change) (cdr change)) (save-buffer))
        (let ((saved (my/calendar-view-file-text "calendar-personal.org")))
          (should (equal (cadr (should-error (my/org-calendar-view--update event 0 60 nil 'timed)
                                             :type 'user-error))
                         "Repeating Google event: edit it in Google Calendar"))
          (should-error (my/org-calendar-view--delete event) :type 'user-error)
          (should (equal saved (my/calendar-view-file-text "calendar-personal.org"))))
        (with-current-buffer buffer
          (org-entry-delete nil (car change)) (save-buffer)))
      (should (equal original (my/calendar-view-file-text "calendar-personal.org")))
      (with-current-buffer buffer
        (goto-char (point-min)) (org-next-visible-heading 1)
        (org-todo "TODO") (save-buffer))
      (should-error (my/org-calendar-view--update event 0 60 nil 'timed) :type 'user-error)
      (with-current-buffer buffer
        (org-todo 'none) (save-buffer)
        (goto-char (point-max)) (insert "unsaved\n"))
      (should-error (my/org-calendar-view--update event 0 60 nil 'timed) :type 'user-error)
      (with-current-buffer buffer (set-buffer-modified-p nil)))))

(ert-deftest my/calendar-view-refuses-repeating-org-entries ()
  (my/calendar-test-workspace
    (my/org-test-append "calendar-work.org"
                        "\n* Daily\n<2026-10-12 Mon 10:00-11:00 +1d>\n")
    (let ((event (car (apply #'my/org-calendar-view--list (my/calendar-view-test-range))))
          (text (my/calendar-view-file-text "calendar-work.org")))
      (should-error (my/org-calendar-view--update event 0 60 nil 'timed) :type 'user-error)
      (should (equal text (my/calendar-view-file-text "calendar-work.org"))))))

(ert-deftest my/calendar-view-reschedules-renames-and-unschedules-tasks ()
  (my/calendar-test-workspace
    (my/org-test-append "work.org" "\n* TODO Plan\nSCHEDULED: <2026-10-12 Mon 09:00-10:00>\nBody\n")
    (let* ((event (car (apply #'my/org-calendar-view--list (my/calendar-view-test-range))))
           (start (org-timegrid-event-start event))
           (end (org-timegrid-event-end event)))
      (my/org-calendar-view--update event (+ start 1440) (+ end 1440) nil 'timed)
      (should (string-match-p "^SCHEDULED: <2026-10-13 Tue 09:00-10:00>$"
                              (my/calendar-view-file-text "work.org")))
      (my/org-calendar-view--update event (+ start 1440) (+ end 1440) "TODO Plan B" 'timed)
      (should (string-match-p "^\\* TODO Plan B$" (my/calendar-view-file-text "work.org")))
      (should-not (my/org-calendar-view--entry-empty-p event))
      (my/org-calendar-view--delete event)
      (let ((text (my/calendar-view-file-text "work.org")))
        (should (string-match-p "TODO Plan B\nBody" text))
        (should-not (string-match-p "SCHEDULED" text))))))

(ert-deftest my/calendar-view-cancels-google-events-instead-of-deleting-them ()
  (my/calendar-test-workspace
    (my/org-test-append "calendar-personal.org"
                        "\n* Event\n:org-gcal:\n<2026-10-13 Tue 10:00-11:00>\n:END:\n")
    (let ((event (car (apply #'my/org-calendar-view--list (my/calendar-view-test-range))))
          (original (my/calendar-view-file-text "calendar-personal.org")))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
        (should-error (my/org-calendar-view--delete event) :type 'user-error))
      (should (equal original (my/calendar-view-file-text "calendar-personal.org")))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        (my/org-calendar-view--delete event))
      (let ((text (my/calendar-view-file-text "calendar-personal.org")))
        (should (string-match-p "^\\* CANCELLED Event$" text))
        (should (string-match-p "<2026-10-13 Tue 10:00-11:00>" text)))
      (should-not (apply #'my/org-calendar-view--list (my/calendar-view-test-range))))))

(ert-deftest my/calendar-view-deletes-local-work-events-with-their-entry ()
  (my/calendar-test-workspace
    (my/org-test-append "calendar-work.org" "\n* Local\n:org-gcal:\n<2026-10-13 Tue 10:00-11:00>\n:END:\n")
    (let ((event (car (apply #'my/org-calendar-view--list (my/calendar-view-test-range)))))
      (my/org-calendar-view--delete event)
      (should (my/org-calendar-view--entry-empty-p event))
      (my/org-calendar-view--delete-entry event)
      (should-not (string-match-p "Local" (my/calendar-view-file-text "calendar-work.org"))))))

(ert-deftest my/calendar-view-undo-and-redo-restore-edits-and-creations ()
  (my/calendar-test-workspace
    (my/org-test-append "calendar-personal.org"
                        "\n* Event\n:org-gcal:\n<2026-10-13 Tue 10:00-11:00>\n:END:\n")
    (cl-letf (((symbol-function 'run-at-time) my/calendar-view-test-real-run-at-time))
     (let* ((org-timegrid-org--undo-transactions nil)
           (org-timegrid-org--redo-transactions nil)
           (event (car (apply #'my/org-calendar-view--list (my/calendar-view-test-range))))
           (original (my/calendar-view-file-text "calendar-personal.org")))
      (my/org-calendar-view--update event (+ (org-timegrid-event-start event) 60)
                                    (+ (org-timegrid-event-end event) 60) nil 'timed)
      (let ((moved (my/calendar-view-file-text "calendar-personal.org")))
        (should-not (equal moved original))
        (my/org-calendar-view--undo nil nil)
        (should (equal original (my/calendar-view-file-text "calendar-personal.org")))
        (my/org-calendar-view--undo nil t)
        (should (equal moved (my/calendar-view-file-text "calendar-personal.org")))
        (my/org-calendar-view--undo nil nil))
      (my/org-calendar-view--create "New" 0 60 nil 'work-task 'timed)
      (should (string-match-p "TODO New" (my/calendar-view-file-text "work.org")))
      (my/org-calendar-view--undo nil nil)
      (should-not (string-match-p "TODO New" (my/calendar-view-file-text "work.org")))))))

(ert-deftest my/calendar-view-task-keys-run-on-tasks-save-and-refuse-events ()
  (my/calendar-test-workspace
    (my/org-test-append "work.org" "\n* TODO Task\nSCHEDULED: <2026-10-12 Mon 10:00>\n")
    (my/org-test-append "calendar-personal.org" "\n* Event\n:org-gcal:\n<2026-10-13 Tue 10:00-11:00>\n:END:\n")
    (let* ((events (apply #'my/org-calendar-view--list (my/calendar-view-test-range)))
           (task (my/calendar-view-test-event events "TODO Task"))
           (event (my/calendar-view-test-event events "Event"))
           (selected task) ran
           (command (alist-get "C-c C-t" my/org-calendar-view-task-commands nil nil #'equal)))
      (cl-letf (((symbol-function 'org-timegrid--selected-block)
                 (lambda () (org-timegrid-block-create :event selected)))
                ((symbol-function 'org-timegrid-org--run-selected-command)
                 (lambda (command)
                   (setq ran command)
                   (with-current-buffer (marker-buffer (plist-get (org-timegrid-event-source task) :marker))
                     (goto-char (point-max)) (insert "touched\n")))))
        (funcall command)
        (should (eq ran 'org-todo))
        (should (string-match-p "touched" (my/calendar-view-file-text "work.org")))
        (setq selected event ran nil)
        (should-error (funcall command) :type 'user-error)
        (should-not ran)))))

(ert-deftest my/calendar-view-ui-binds-edit-keys-and-blocks-only-unsafe-ones ()
  (save-window-excursion
    (unwind-protect
        (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                  ((symbol-function 'image-type-available-p) (lambda (_) t))
                  ((symbol-function 'org-timegrid-open)
                    (lambda (backend)
                      (should (eq backend my/org-calendar-view--backend))
                      (should (equal display-buffer-overriding-action
                                     '((display-buffer-same-window) (inhibit-same-window . nil))))
                      (switch-to-buffer (get-buffer-create my/org-calendar-view-buffer)))))
          (my/org-calendar-week)
          (should (equal mode-name "Week (both)"))
          (dolist (key '("C-w" "C-y" "M-y" "M-w"))
            (should (eq (key-binding (kbd key)) #'my/org-calendar-view-no-copy)))
          (dolist (key '("C-c C-w" "z" "C-c C-z"))
            (should (eq (key-binding (kbd key)) #'my/org-calendar-view-blocked)))
          (pcase-dolist (`(,key . ,command) my/org-calendar-view-task-commands)
            (should (eq (key-binding (kbd key)) command)))
          (pcase-dolist (`(,key . ,command) my/org-calendar-view-keys)
            (should (fboundp command))
            (should (eq (key-binding (kbd key)) command)))
          (dolist (entry '(("c" . org-timegrid-create-at-cursor) ("e" . org-timegrid-edit-selected-title)
                           ("t" . org-timegrid-retime-selected) ("d" . org-timegrid-remove-selected)
                           ("u" . org-timegrid-undo) ("C-r" . org-timegrid-redo)
                           ("J" . org-timegrid-move-later) ("K" . org-timegrid-move-earlier)
                           ("<" . org-timegrid-move-previous-day) (">" . org-timegrid-move-next-day)
                           ("DEL" . org-timegrid-remove-or-page-up) ("M-<down>" . org-timegrid-move-later)
                           ("S-<down>" . org-timegrid-grow-end) ("C-S-<up>" . org-timegrid-grow-start)))
            (should (eq (key-binding (kbd (car entry))) (cdr entry))))
          (should (eq (key-binding (kbd "j")) #'org-timegrid-cursor-forward))
          (should (eq (key-binding (kbd "w")) #'my/org-calendar-view-next-event))
          (should (eq (key-binding (kbd "$")) #'org-timegrid-cursor-day-end))
          (should (eq (key-binding (kbd "0")) #'org-timegrid-cursor-day-start))
          (should (eq (key-binding (kbd "[")) #'org-timegrid-previous-week))
          (should (eq (key-binding (kbd "F")) #'my/org-calendar-view-filter))
          (should (eq (key-binding (kbd "RET")) #'org-timegrid-open-at-cursor)))
      (when-let* ((buffer (get-buffer my/org-calendar-view-buffer))) (kill-buffer buffer)))))

(ert-deftest my/calendar-view-help-menu-lists-the-edit-group-and-defines-a-prefix ()
  (require 'transient)
  (let ((layout (my/org-calendar-view--menu-layout))
        (groups (mapcar #'car my/org-calendar-view-key-groups)))
    (should (member "Edit" groups))
    (should (equal (aref layout 0) :description))
    (should (equal (aref layout 1) "Week view · SPC n v"))
    (eval `(transient-define-prefix my/org-calendar-view-test-menu ()
             "Week view keys."
             ,layout)
          t)
    (should (get 'my/org-calendar-view-test-menu 'transient--layout))))

(ert-deftest my/calendar-view-profile-filter-keeps-tasks-events-and-deadline-indicators ()
  (my/calendar-test-workspace
    (my/org-test-append "work.org" "\n* TODO Work task\nSCHEDULED: <2026-10-12 Mon 09:00> DEADLINE: <2026-10-14 Wed>\n")
    (my/org-test-append "calendar-work.org" "\n* Work event\n<2026-10-12 Mon 10:00-11:00>\n")
    (my/org-test-append "personal.org" "\n* WAIT Personal task\nSCHEDULED: <2026-10-12 Mon 09:00>\n")
    (my/org-test-append "calendar-personal.org" "\n* Personal event\n<2026-10-12 Mon>\n")
    (dolist (profile '(nil "work" "personal"))
      (let* ((my/org-calendar-view-profile profile)
             (events (apply #'my/org-calendar-view--list (my/calendar-view-test-range))))
        (should (= (length events) (pcase profile ("work" 3) ("personal" 2) (_ 5))))
        (when profile
          (dolist (event events)
            (should (string-match-p (capitalize profile) (org-timegrid-event-title event)))))))))

(ert-deftest my/calendar-view-all-day-multi-day-and-overnight-ranges-stay-intact ()
  (my/calendar-test-workspace
    (my/org-test-append "calendar-work.org"
                        "\n* Overnight\n<2026-10-12 Mon 23:30>--<2026-10-13 Tue 00:30>\n* Three days\n<2026-10-13 Tue>--<2026-10-15 Thu>\n")
    (let* ((events (apply #'my/org-calendar-view--list (my/calendar-view-test-range)))
           (overnight (seq-find (lambda (event) (equal (org-timegrid-event-title event) "Overnight")) events))
           (days (seq-find (lambda (event) (equal (org-timegrid-event-title event) "Three days")) events)))
      (should (= (length events) 2))
      (should (= (- (org-timegrid-event-end overnight) (org-timegrid-event-start overnight)) 60))
      (should-not (org-timegrid-event-all-day overnight))
      (should (org-timegrid-event-all-day days))
      (should (= (- (org-timegrid-event-end days) (org-timegrid-event-start days)) (* 3 1440))))))

(ert-deftest my/calendar-view-source-navigation-keeps-point-and-recurrence-identity ()
  (my/calendar-test-workspace
    (my/org-test-append "calendar-work.org" "\n* Visit event\n<2026-10-12 Mon 10:00-11:00>\nPrivate note.\n")
    (let* ((event (car (apply #'my/org-calendar-view--list (my/calendar-view-test-range))))
           (marker (plist-get (org-timegrid-event-source event) :heading-marker)))
      (save-window-excursion
        (my/org-calendar-view--visit event)
        (should (eq (current-buffer) (marker-buffer marker)))
        (should (= (point) (marker-position marker)))
        (should-not (buffer-modified-p)))
      (with-current-buffer (marker-buffer marker)
        (goto-char (point-max))
        (let ((position (point)))
          (apply #'my/org-calendar-view--list (my/calendar-view-test-range))
          (should (= position (point))))))))

(ert-deftest my/calendar-view-rendering-failure-cannot-fail-calendar-sync ()
  (let ((buffer (get-buffer-create my/org-calendar-view-buffer)) refreshed)
    (unwind-protect
        (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) (selected-window)))
                  ((symbol-function 'org-timegrid--refresh-data)
                   (lambda () (setq refreshed t) (error "Disposable render failure"))))
          (my/org-calendar-view-refresh-visible "up to date")
          (should refreshed))
      (kill-buffer buffer))))
