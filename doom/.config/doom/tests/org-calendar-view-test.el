;;; org-calendar-view-test.el -*- lexical-binding: t; -*-
;; Run with org-timegrid and the normal calendar-test dependencies on load-path.
(unless (featurep 'org-calendar-auto)
  (load (expand-file-name "org-calendar-auto-test.el" (file-name-directory load-file-name)) nil t))
(load (expand-file-name "../lisp/org-calendar-view.el" (file-name-directory load-file-name)) nil t)

(defun my/calendar-view-test-range ()
  (let ((day (calendar-absolute-from-gregorian '(10 12 2026))))
    (list (* day 1440) (* (+ day 7) 1440))))

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

(ert-deftest my/calendar-view-backend-has-no-write-callbacks-or-editable-source-markers ()
  (dolist (getter '(org-timegrid-backend-create-function org-timegrid-backend-update-function
                   org-timegrid-backend-delete-function org-timegrid-backend-delete-entry-function
                   org-timegrid-backend-undo-function org-timegrid-backend-transaction-function))
    (should-not (funcall getter my/org-calendar-view--backend)))
  (my/calendar-test-workspace
    (my/org-test-append "work.org" "\n* TODO Protected\nSCHEDULED: <2026-10-12 Mon 10:00>\n")
    (let* ((event (car (apply #'my/org-calendar-view--list (my/calendar-view-test-range))))
           (block (org-timegrid-block-create :event event)))
      (cl-letf (((symbol-function 'org-timegrid--selected-block) (lambda () block))
                ((symbol-function 'org-todo) (lambda (&rest _) (ert-fail "No graphical state changes"))))
        (should-error (org-timegrid-org-todo) :type 'user-error)))))

(ert-deftest my/calendar-view-ui-disables-mutating-shortcuts-and-retains-navigation ()
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
          (dolist (key '("d" "e" "t" "C-c C-t" "C-c C-w" "C-y"))
            (should (eq (key-binding (kbd key)) #'my/org-calendar-view-read-only)))
          (pcase-dolist (`(,key . ,command) my/org-calendar-view-keys)
            (should (eq (key-binding (kbd key)) command)))
          (should (eq (key-binding (kbd "j")) #'org-timegrid-cursor-forward))
          (should (eq (key-binding (kbd "w")) #'my/org-calendar-view-next-event))
          (should (eq (key-binding (kbd "$")) #'org-timegrid-cursor-day-end))
          (should (eq (key-binding (kbd "[")) #'org-timegrid-previous-week))
          (should (eq (key-binding (kbd "F")) #'my/org-calendar-view-filter))
          (should (eq (key-binding (kbd "RET")) #'org-timegrid-open-at-cursor)))
      (when-let* ((buffer (get-buffer my/org-calendar-view-buffer))) (kill-buffer buffer)))))

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
