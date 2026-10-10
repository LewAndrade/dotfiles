;;; org-workflow-test.el -*- lexical-binding: t; -*-
;; Run: emacs -Q --batch -l tests/org-workflow-test.el -f ert-run-tests-batch-and-exit
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'org)
(require 'org-agenda)
(require 'org-capture)

(setq native-comp-enable-subr-trampolines nil)
(defconst my/org-calendar-test-worker-file
  (expand-file-name "../lisp/org-calendar-auth.el" (file-name-directory load-file-name)))

;; Evaluate the actual helpers, without Doom, credentials, or network access.
(with-temp-buffer
  (insert-file-contents
   (expand-file-name "../config.org" (file-name-directory load-file-name)))
  (dolist (section '("org-workflow" "org-calendar"))
    (goto-char (point-min))
    (search-forward (concat ";; BEGIN " section))
    (forward-line 1)
    (let ((start (point))
          (end (progn (search-forward (concat ";; END " section))
                      (line-beginning-position))))
      (save-restriction
        (narrow-to-region start end)
        (goto-char (point-min))
        (while (progn (skip-chars-forward " \t\n\r") (< (point) (point-max)))
          (eval (read (current-buffer)) t))))))

(defvar org-gcal-client-id nil)
(defvar org-gcal-client-secret nil)
(defvar org-gcal-fetch-file-alist nil)
(defvar org-gcal-auto-archive nil)
(defvar org-gcal-remove-api-cancelled-events nil)
(defvar org-gcal-managed-newly-fetched-mode nil)
(defvar org-gcal-managed-update-existing-mode nil)
(defvar org-gcal-managed-post-at-point-update-existing nil)
(defvar oauth2-auto-plstore nil)
(defvar org-time-was-given nil)

(ert-deftest my/org-calendar-access-token-never-starts-editor-login ()
  (let ((my/org-gcal-test-calendar-id "test@group.calendar.google.com")
        (my/org-calendar-access-token nil)
        (my/org-calendar-token-expiration nil))
    (should-error
     (my/org-calendar-access-token (lambda (&rest _) (ert-fail "Blocking login"))
                                   my/org-gcal-test-calendar-id)
     :type 'user-error)
    (setq my/org-calendar-access-token "test-token"
          my/org-calendar-token-expiration (+ (float-time) 3600))
    (should (equal (my/org-calendar-access-token #'ignore my/org-gcal-test-calendar-id)
                   "test-token"))
    (should (equal (my/org-calendar-access-token (lambda (_) "other-provider") "other")
                   "other-provider"))))

(ert-deftest my/org-calendar-auth-url-opens-zen-and-copies-link ()
  (let (copied launch)
    (cl-letf (((symbol-function 'kill-new) (lambda (url) (setq copied url)))
              ((symbol-function 'display-graphic-p) (lambda (&rest _) nil))
              ((symbol-function 'display-buffer) #'ignore)
              ((symbol-function 'file-directory-p) (lambda (&rest _) t))
              ((symbol-function 'start-process) (lambda (&rest args) (setq launch args))))
      (unwind-protect
          (progn
            (my/org-calendar-open-auth-url "https://accounts.google.com/test")
            (should (equal copied "https://accounts.google.com/test"))
            (should (equal launch '("org-calendar-zen" nil "open" "-a"
                                    "/Applications/Zen.app" "https://accounts.google.com/test"))))
        (when (get-buffer "*Personal Calendar Authorization*")
          (kill-buffer "*Personal Calendar Authorization*"))))))

(defmacro my/org-test-workspace (&rest body)
  "Run BODY with isolated central files and no access to real notes."
  (declare (indent 0))
  `(let* ((directory (make-temp-file "org-workflow-test-" t))
          (org-directory directory)
          (org-agenda-files nil)
          (org-agenda-custom-commands nil)
          (org-capture-templates nil)
          (org-refile-targets nil)
          (my/org-calendar-access-token "test-token")
          (my/org-calendar-token-expiration (+ (float-time) 3600))
          (org-agenda-buffer-name "*Org Workflow Test Agenda*")
          (org-agenda-sticky nil)
          (org-agenda-inhibit-startup t)
          (org-id-locations-file (expand-file-name ".orgids" directory)))
     (unwind-protect
         (progn
           (my/org-configure-workflow)
           (dolist (profile '("work" "personal"))
             (let ((category (capitalize profile)))
               (write-region (format "#+category: %s\n* Inbox\n* Tasks\n* Notes\n" category)
                             nil (my/org-file (concat profile ".org")) nil 'silent)
               (write-region (format "#+category: %s\n" category)
                             nil (my/org-file (concat "calendar-" profile ".org")) nil 'silent)))
           ,@body)
       (dolist (buffer (buffer-list))
         (with-current-buffer buffer
           (when (or (derived-mode-p 'org-agenda-mode)
                     (and buffer-file-name (file-in-directory-p buffer-file-name directory)))
             (set-buffer-modified-p nil)
             (kill-buffer buffer))))
       (delete-directory directory t))))

(defun my/org-test-append (name text)
  (write-region text nil (my/org-file name) t 'silent))

(defun my/org-test-date (offset)
  (let ((date (calendar-gregorian-from-absolute (+ (org-today) offset))))
    (format "%04d-%02d-%02d" (nth 2 date) (car date) (nth 1 date))))

(defun my/org-test-agenda (key)
  (save-window-excursion
    (org-agenda nil key)
    (should (derived-mode-p 'org-agenda-mode))
    (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest my/org-workflow-explicit-files-and-refile-targets ()
  (my/org-test-workspace
    (should (= (length (org-agenda-files)) 4))
    (should-not (member (my/org-file "notes.org") (org-agenda-files)))
    (should-not (member (my/org-file "work/brl-cash-returns.org") (org-agenda-files)))
    (should (equal (caar org-refile-targets)
                   (list (my/org-file "work.org") (my/org-file "personal.org"))))
    (should-error (my/org-profile-files "other") :type 'user-error)))

(ert-deftest my/org-workflow-only-five-states ()
  (my/org-test-workspace
    (with-temp-buffer
      (org-mode)
      (should (equal org-not-done-keywords '("TODO" "DOING" "WAIT")))
      (should (equal org-done-keywords '("DONE" "CANCELLED"))))))

(ert-deftest my/org-workflow-state-selector-order-preserves-extra-states ()
  (let ((org-todo-keywords-for-agenda
         '("CANCELLED" "DONE" "WAIT" "DOING" "TODO" "ACTIVE" "BLOCKED")))
    (my/org-order-agenda-keywords)
    (should (equal org-todo-keywords-for-agenda
                   '("TODO" "DOING" "WAIT" "DONE" "CANCELLED" "ACTIVE" "BLOCKED")))))

(ert-deftest my/org-workflow-todo-list-filter-numbers-follow-workflow-order ()
  (my/org-test-workspace
    (my/org-test-append "personal.org" "\n* TODO An open task\n")
    (unwind-protect
        (progn
          (advice-add 'org-agenda-prepare :after #'my/org-order-agenda-keywords)
          (let ((agenda (my/org-test-agenda "t")))
            (should (string-match-p
                     "(1)TODO (2)DOING (3)WAIT (4)DONE (5)CANCELLED"
                     (replace-regexp-in-string "[[:space:]]+" " " agenda)))))
      (advice-remove 'org-agenda-prepare #'my/org-order-agenda-keywords))))

(ert-deftest my/org-workflow-capture-menu-and-event-separation ()
  (my/org-test-workspace
    (should (equal (mapcar #'car org-capture-templates)
                   '("w" "wt" "wn" "we" "wa" "p" "pt" "pn" "pe" "pa")))
    (dolist (key '("we" "wa" "pe" "pa"))
      (let ((template (assoc key org-capture-templates)))
        (should (equal (car (nth 3 template)) 'file))
        (should (string-match-p "calendar-" (cadr (nth 3 template))))
        (should-not (string-match-p "TODO\\|SCHEDULED\\|calendar-id" (nth 4 template)))))))

(ert-deftest my/org-workflow-task-capture-saves-to-correct-profile ()
  (my/org-test-workspace
    (dolist (case '(("wt" "work.org" "Work capture")
                    ("pt" "personal.org" "Personal capture")))
      (save-window-excursion
        (org-capture nil (car case))
        (insert (nth 2 case))
        (org-capture-finalize))
      (with-temp-buffer
        (insert-file-contents (my/org-file (nth 1 case)))
        (should (search-forward (concat "** TODO " (nth 2 case)) nil t))))))

(ert-deftest my/org-workflow-note-capture-has-no-todo ()
  (my/org-test-workspace
    (save-window-excursion
      (org-capture nil "pn")
      (insert "A private note")
      (org-capture-finalize))
    (with-temp-buffer
      (insert-file-contents (my/org-file "personal.org"))
      (should (search-forward "** A private note" nil t))
      (should-not (string-match-p "TODO" (buffer-string))))))

(ert-deftest my/org-workflow-event-capture-is-local-and-has-a-time-range ()
  (my/org-test-workspace
    (dolist (case '(("pe" "calendar-personal.org") ("we" "calendar-work.org")))
      (let ((date-calls 0) (duration-calls 0))
        (cl-letf (((symbol-function 'org-read-date)
                   (lambda (&rest args)
                     (should (car args)) (should (nth 1 args))
                     (cl-incf date-calls) (encode-time 0 0 10 9 10 2026)))
                  ((symbol-function 'read-string)
                   (lambda (_prompt _initial _history default &rest _)
                     (cl-incf duration-calls) (should (equal default "1h")) default))
                  ((symbol-function 'org-gcal-post-at-point)
                   (lambda (&rest _) (ert-fail "Capture must not publish"))))
          (save-window-excursion
            (org-capture nil (car case))
            (insert "Local appointment")
            (org-capture-finalize)))
        (should (= date-calls 1))
        (should (= duration-calls 1)))
      (with-temp-buffer
        (insert-file-contents (my/org-file (cadr case)))
        (should (search-forward "* Local appointment" nil t))
        (should (string-match-p "<2026-10-09 Fri 10:00>--<2026-10-09 Fri 11:00>"
                                (buffer-string)))
        (should-not (string-match-p "TODO\\|calendar-id\\|entry-id" (buffer-string)))))))

(ert-deftest my/org-workflow-event-duration-accepts-minute-hour-and-combined-input ()
  (dolist (case '(("30m" . 30) ("1h" . 60) ("2h" . 120) ("1h30m" . 90)
                  ("1h 30m" . 90) (" 30m " . 30) ("0.5h" . 30)
                  ("90" . 90) ("1:30" . 90) ("30 min" . 30)
                  ("30 minutes" . 30) ("1 hour" . 60) ("2 hours" . 120)
                  ("1 hour 30 minutes" . 90) ("1 hour and 30 minutes" . 90)
                  ("1 hr 30 mins" . 90) (" 1 HOUR " . 60) ("0.5 hours" . 30)
                  ("1h30" . 90) ("2h15" . 135) ("1h05" . 65) ("0h30" . 30)
                  ("1H30" . 90) ("1h 30" . 90)))
    (should (= (my/org-event-duration-minutes (car case)) (cdr case)))))

(ert-deftest my/org-workflow-event-duration-rejects-zero-negative-and-fractional-minutes ()
  (dolist (duration '("" "nonsense" "0m" "-30m" "0.5m" "1s" "1h junk"
                      "1 ho" "1 hour and" "1 hour -30 minutes" "1h-30" "0h0"))
    (should-error (my/org-event-duration-minutes duration) :type 'user-error)))

(ert-deftest my/org-workflow-timed-range-rolls-overnight-and-into-the-next-year ()
  (dolist (case '((2026 10 9 "<2026-10-10 Sat 01:00>")
                  (2026 12 31 "<2027-01-01 Fri 01:00>")))
    (cl-letf (((symbol-function 'org-read-date)
               (lambda (&rest _) (encode-time 0 30 23 (nth 2 case) (nth 1 case) (car case))))
              ((symbol-function 'read-string) (lambda (&rest _) "1h30")))
      (should (equal (my/org-capture-timed-range)
                     (concat (format-time-string "<%Y-%m-%d %a %H:%M>"
                                                 (encode-time 0 30 23 (nth 2 case) (nth 1 case) (car case)))
                             "--" (nth 3 case)))))))

(ert-deftest my/org-workflow-timed-range-retries-only-the-duration-after-invalid-input ()
  (let ((date-calls 0) (inputs '("0m" "nonsense" "30m")))
    (cl-letf (((symbol-function 'org-read-date)
               (lambda (&rest _) (cl-incf date-calls) (encode-time 0 0 10 9 10 2026)))
              ((symbol-function 'read-string)
               (lambda (&rest _) (unless inputs (ert-fail "Unexpected extra duration prompt")) (pop inputs))))
      (should (equal (my/org-capture-timed-range)
                     "<2026-10-09 Fri 10:00>--<2026-10-09 Fri 10:30>")))
    (should (= date-calls 1))
    (should-not inputs)))

(ert-deftest my/org-workflow-timed-range-duration-is-elapsed-time-across-dst ()
  (let ((previous-zone (getenv "TZ")))
    (unwind-protect
        (progn
          (set-time-zone-rule "America/New_York")
          (cl-letf (((symbol-function 'org-read-date)
                     (lambda (&rest _) (encode-time 0 30 1 8 3 2026)))
                    ((symbol-function 'read-string) (lambda (&rest _) "2h")))
            (should (equal (my/org-capture-timed-range)
                           "<2026-03-08 Sun 01:30>--<2026-03-08 Sun 04:30>"))))
      (set-time-zone-rule previous-zone))))

(ert-deftest my/org-workflow-duration-preview-shows-default-and-live-end-dates ()
  (let ((start (encode-time 0 30 23 31 12 2026)))
    (should (string-match-p "Ends 2027-01-01 Fri 00:30 (default: 1h)"
                            (my/org-event-duration-preview start "")))
    (should (string-match-p "Ends 2027-01-01 Fri 00:30 (default: 1h)"
                            (my/org-event-duration-preview start "   ")))
    (should (string-match-p "Ends 2027-01-01 Fri 01:00"
                            (my/org-event-duration-preview start "1 hour 30 minutes")))
    (should (string-match-p "Ends 2027-01-01 Fri 01:00"
                            (my/org-event-duration-preview start "1h30")))
    (should (string-match-p "Ends 2026-12-31 Thu 23:31"
                            (my/org-event-duration-preview start "1")))
    (should (string-match-p "Ends 2027-01-01 Fri 00:00"
                            (my/org-event-duration-preview start "30")))
    (dolist (input '("1 ho" "oops" "0m"))
      (should (string-match-p "Try 30 minutes" (my/org-event-duration-preview start input)))
      (should-not (string-match-p "Ends" (my/org-event-duration-preview start input))))))

(ert-deftest my/org-workflow-duration-reader-updates-after-typing-without-changing-input ()
  (with-temp-buffer
    (let ((preview-buffer (current-buffer)) (minibuffer-setup-hook nil) overlay)
      (setq-local post-command-hook '(ignore))
      (cl-letf (((symbol-function 'minibuffer-contents-no-properties) #'buffer-string)
                ((symbol-function 'read-string)
                 (lambda (&rest _)
                   (with-current-buffer preview-buffer
                     (run-hooks 'minibuffer-setup-hook)
                     (setq overlay (car (append (car (overlay-lists)) (cdr (overlay-lists)))))
                     (should overlay)
                     (should (string-match-p "Ends 2026-10-09 Fri 11:00 (default: 1h)"
                                             (overlay-get overlay 'after-string)))
                     (insert "30 minutes") (run-hooks 'post-command-hook)
                     (should (equal (buffer-string) "30 minutes"))
                     (should (string-match-p "Ends 2026-10-09 Fri 10:30"
                                             (overlay-get overlay 'after-string)))
                     (erase-buffer) (insert "1 ho") (run-hooks 'post-command-hook)
                     (should (string-match-p "Try 30 minutes" (overlay-get overlay 'after-string)))
                     (erase-buffer) (insert "2 hours") (run-hooks 'post-command-hook)
                     (should (string-match-p "Ends 2026-10-09 Fri 12:00"
                                             (overlay-get overlay 'after-string)))
                     (buffer-string)))))
        (should (equal (my/org-read-event-duration (encode-time 0 0 10 9 10 2026)) "2 hours")))
      (should-not (overlay-buffer overlay))
      (should (equal post-command-hook '(ignore)))
      (should-not minibuffer-setup-hook))))

(ert-deftest my/org-workflow-duration-reader-removes-preview-and-hook-on-abort ()
  (with-temp-buffer
    (let ((preview-buffer (current-buffer)) (minibuffer-setup-hook nil) overlay)
      (setq-local post-command-hook '(ignore))
      (cl-letf (((symbol-function 'minibuffer-contents-no-properties) #'buffer-string)
                ((symbol-function 'read-string)
                 (lambda (&rest _)
                   (with-current-buffer preview-buffer
                     (run-hooks 'minibuffer-setup-hook)
                     (setq overlay (car (append (car (overlay-lists)) (cdr (overlay-lists)))))
                     (signal 'quit nil)))))
        (should (eq (condition-case nil
                        (my/org-read-event-duration (encode-time 0 0 10 9 10 2026))
                      (quit 'aborted)) 'aborted)))
      (should-not (overlay-buffer overlay))
      (should (equal post-command-hook '(ignore)))
      (should-not minibuffer-setup-hook))))

(ert-deftest my/org-workflow-duration-reader-blank-input-uses-the-previewed-default ()
  (dolist (input '("" "   "))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) input)))
      (should (equal (my/org-read-event-duration (encode-time 0 0 10 9 10 2026)) "1h")))))

(ert-deftest my/org-workflow-all-day-capture-same-date-is-one-day ()
  (my/org-test-workspace
    (dolist (case '(("pa" "calendar-personal.org") ("wa" "calendar-work.org")))
      (let* ((day (encode-time 0 0 0 12 10 2026))
             (calls nil))
        (cl-letf (((symbol-function 'org-read-date)
                   (lambda (&rest args) (push args calls) day)))
          (save-window-excursion
            (org-capture nil (car case))
            (insert "All-day appointment")
            (org-capture-finalize)))
        (should (= (length calls) 2))
        (should-not (caar calls))
        (should-not (car (cadr calls)))
        (should (equal (nth 4 (car calls)) day))
        (with-temp-buffer
          (insert-file-contents (my/org-file (cadr case)))
          (should (search-forward "* All-day appointment" nil t))
          (should (search-forward (format-time-string "<%Y-%m-%d %a>" day) nil t))
          (should-not (string-match-p "[0-9][0-9]:[0-9][0-9]\\|>--<" (buffer-string))))))))

(ert-deftest my/org-workflow-all-day-capture-multiple-days-is-inclusive ()
  (my/org-test-workspace
    (let ((dates (list (encode-time 0 0 0 12 10 2026) (encode-time 0 0 0 14 10 2026))))
      (cl-letf (((symbol-function 'org-read-date) (lambda (&rest _) (pop dates))))
        (save-window-excursion
          (org-capture nil "pa")
          (insert "Several days")
          (org-capture-finalize))))
    (with-temp-buffer
      (insert-file-contents (my/org-file "calendar-personal.org"))
      (should (string-match-p "<2026-10-12 Mon>--<2026-10-14 Wed>" (buffer-string)))
      (should-not (string-match-p "[0-9][0-9]:[0-9][0-9]" (buffer-string))))))

(ert-deftest my/org-workflow-all-day-capture-rejects-backward-date-range ()
  (let ((dates (list (encode-time 0 0 0 14 10 2026) (encode-time 0 0 0 12 10 2026))))
    (cl-letf (((symbol-function 'org-read-date) (lambda (&rest _) (pop dates))))
      (should-error (my/org-capture-all-day-range) :type 'user-error))))

(ert-deftest my/org-workflow-today-is-focused ()
  (my/org-test-workspace
    (my/org-test-append "work.org"
                        (format "\n* TODO Planned today\nSCHEDULED: <%s>\n* TODO Undated task\n* TODO Future task\nSCHEDULED: <%s>\n* DONE Finished\nSCHEDULED: <%s>\n"
                                (my/org-test-date 0) (my/org-test-date 14) (my/org-test-date 0)))
    (my/org-test-append "calendar-personal.org"
                        (format "\n* Dentist event\n:org-gcal:\n<%s 10:00-11:00>\n:END:\n" (my/org-test-date 0)))
    (my/org-test-append "cheatsheet.org" "* TODO Pollution\n")
    (let ((agenda (my/org-test-agenda "d")))
      (should (string-match-p "Planned today" agenda))
      (should (string-match-p "Dentist event" agenda))
      (dolist (absent '("Undated task" "Future task" "Finished" "Pollution"))
        (should-not (string-match-p absent agenda))))))

(ert-deftest my/org-workflow-review-keeps-undated-and-future-tasks ()
  (my/org-test-workspace
    (my/org-test-append "work.org"
                        (format "\n* TODO Undated task\n* DOING In progress\n* WAIT Waiting task\n* TODO Future task\nSCHEDULED: <%s>\n* DONE Finished\n* CANCELLED Dropped\n"
                                (my/org-test-date 14)))
    (my/org-test-append "personal.org" "\n* TODO Personal task\n* Plain note\n")
    (let ((agenda (my/org-test-agenda "r")))
      (dolist (present '("Undated task" "In progress" "Waiting task" "Future task" "Personal task"))
        (should (string-match-p present agenda)))
      (dolist (absent '("Finished" "Dropped" "Plain note"))
         (should-not (string-match-p absent agenda))))))

(ert-deftest my/org-workflow-review-omits-only-tasks-already-in-today ()
  (my/org-test-workspace
    (my/org-test-append "work.org"
                        (format "\n* TODO Today scheduled\nSCHEDULED: <%s>\n* TODO Earlier scheduled\nSCHEDULED: <%s>\n* TODO Near deadline\nDEADLINE: <%s>\n* TODO Overdue deadline\nDEADLINE: <%s>\n* TODO Today active timestamp\n<%s>\n* TODO Undated remaining\n* TODO Future scheduled\nSCHEDULED: <%s>\n* TODO Far deadline\nDEADLINE: <%s>\n"
                                (my/org-test-date 0) (my/org-test-date -2)
                                (my/org-test-date 2) (my/org-test-date -2)
                                (my/org-test-date 0) (my/org-test-date 14)
                                (my/org-test-date 30)))
    (save-window-excursion
      (org-agenda nil "r")
      (dotimes (_ 2)
        (let* ((text (buffer-substring-no-properties (point-min) (point-max)))
               (split (string-match "Other open tasks" text))
               (today (substring text 0 split)) (other (substring text split)))
          (dolist (title '("Today scheduled" "Earlier scheduled" "Near deadline"
                           "Overdue deadline" "Today active timestamp"))
            (should (string-match-p title today))
            (should-not (string-match-p title other)))
          (dolist (title '("Undated remaining" "Future scheduled" "Far deadline"))
            (should (string-match-p title other))))
        (org-agenda-redo)))))

(ert-deftest my/org-workflow-review-matches-source-not-title-and-keeps-child-tasks ()
  (my/org-test-workspace
    (my/org-test-append "work.org"
                        (format "\n* TODO Shared title\nSCHEDULED: <%s>\n** TODO Undated child\n* TODO Shared title\n"
                                (my/org-test-date 0)))
    (my/org-test-append "personal.org" "\n* TODO Shared title\n")
    (dolist (view '(("r" . 3) ("w" . 2) ("p" . 1)))
      (let ((text (my/org-test-agenda (car view))))
        (should (= (cdr view)
                   (cl-count-if (lambda (line) (string-match-p "Shared title" line))
                                (split-string text "\n"))))
        (when (member (car view) '("r" "w"))
          (let ((other (substring text (string-match "Other open tasks" text))))
            (should (string-match-p "Undated child" other)))))
      (dolist (name '("work.org" "personal.org"))
        (with-current-buffer (find-file-noselect (my/org-file name))
          (should-not (buffer-modified-p)))))))

(ert-deftest my/org-workflow-review-date-changes-move-task-between-sections-without-saving ()
  (my/org-test-workspace
    (my/org-test-append "work.org" "\n* TODO Task to date\n")
    (save-window-excursion
      (org-agenda nil "r")
      (let ((org-log-reschedule nil) (org-log-redeadline nil))
        (dolist (operation `((org-agenda-schedule nil ,(my/org-test-date 0) today)
                             (org-agenda-schedule (4) nil other)
                             (org-agenda-deadline nil ,(my/org-test-date 2) today)
                             (org-agenda-deadline nil ,(my/org-test-date 30) other)
                             (org-agenda-deadline (4) nil other)))
          (goto-char (point-min)) (search-forward "Task to date") (beginning-of-line)
          (funcall (nth 0 operation) (nth 1 operation) (nth 2 operation))
          (should (markerp (org-get-at-bol 'org-hd-marker)))
          (should (string-match-p "Task to date"
                                  (buffer-substring-no-properties (line-beginning-position)
                                                                  (line-end-position))))
          (let* ((text (buffer-substring-no-properties (point-min) (point-max)))
                 (split (string-match "Other open tasks" text))
                 (today (substring text 0 split)) (other (substring text split)))
            (should (= 1 (cl-count-if (lambda (line) (string-match-p "Task to date" line))
                                      (split-string text "\n"))))
            (if (eq (nth 3 operation) 'today)
                (progn (should (string-match-p "Task to date" today))
                       (should-not (string-match-p "Task to date" other)))
              (should (string-match-p "Task to date" other))))
          (with-current-buffer (find-file-noselect (my/org-file "work.org"))
            (should (buffer-modified-p))))))))

(ert-deftest my/org-agenda-style-now-rule-fills-blank-columns-and-adapts-to-window-edge ()
  (my/org-test-workspace
    (my/org-test-append "calendar-personal.org"
                        (format "\n* Event beside rule\n<%s 16:00-18:00>\n" (my/org-test-date 0)))
    (save-window-excursion
      (org-agenda nil "d")
      (goto-char (point-min)) (search-forward "now ─")
      (let* ((heading (- (point) 5)) (end (line-end-position))
             (beg (line-beginning-position)))
        (should-not (org-get-at-bol 'org-hd-marker))
        (should (equal (get-text-property (1- end) 'display)
                       '(space :align-to (- right 1))))
        (should (eq (get-text-property beg 'face) 'my/org-agenda-now-rule))
        (should (eq (get-text-property (1- end) 'face) 'my/org-agenda-now-rule))
        (should-not (eq (get-text-property heading 'face) 'my/org-agenda-now-rule))
        (goto-char beg) (re-search-forward "[0-9][0-9]:[0-9][0-9]" heading)
        (should-not (eq (get-text-property (match-beginning 0) 'face) 'my/org-agenda-now-rule))
        (let ((before (buffer-string)))
          (dotimes (_ 5) (my/org-agenda-style-buffer))
          (should (equal before (buffer-string)))))
      (goto-char (point-min)) (search-forward "Event beside rule")
      (should-not (text-property-any (line-beginning-position) (line-end-position)
                                    'face 'my/org-agenda-now-rule)))))

(ert-deftest my/org-workflow-profile-views-do-not-mix ()
  (my/org-test-workspace
    (my/org-test-append "work.org" "\n* TODO Work task\n")
    (my/org-test-append "personal.org" "\n* TODO Personal task\n")
    (let ((work-view (my/org-test-agenda "w"))
          (personal-view (my/org-test-agenda "p")))
      (should (string-match-p "Work task" work-view))
      (should-not (string-match-p "Personal task" work-view))
      (should (string-match-p "Personal task" personal-view))
      (should-not (string-match-p "Work task" personal-view)))))

(ert-deftest my/org-workflow-grouping-survives-agenda-refresh ()
  (skip-unless (featurep 'org-super-agenda))
  (my/org-test-workspace
    (my/org-test-append "work.org" "\n* DOING Work in progress\n* TODO Work task\n")
    (my/org-test-append "personal.org" "\n* WAIT Personal waiting\n")
    (save-window-excursion
      (org-agenda nil "r")
      (dolist (header '("Work: Doing" "Work: To do" "Personal: Waiting"))
        (should (string-match-p header (buffer-string))))
      (org-agenda-redo)
      (dolist (text '("Work: Doing" "Work: To do" "Personal: Waiting"
                      "Work in progress" "Work task" "Personal waiting"))
          (should (string-match-p text (buffer-string)))))))

(ert-deftest my/org-workflow-late-super-agenda-loading-preserves-default-groups ()
  (skip-unless (require 'org-super-agenda nil t))
  (my/org-test-workspace
    (let ((expected (my/org-today-groups))
          (org-super-agenda-header-map nil)
          (org-super-agenda-show-message nil)
          (org-super-agenda-keep-order nil))
      (should (equal org-super-agenda-groups expected))
      ;; Run the actual package :config forms after the Org workflow setup,
      ;; matching deferred package loading without restarting the user's Emacs.
      (with-temp-buffer
        (insert-file-contents
         (expand-file-name "../config.org" (file-name-directory my/org-calendar-test-worker-file)))
        (goto-char (point-min))
        (search-forward "(use-package! org-super-agenda")
        (goto-char (match-beginning 0))
        (let ((forms (cdr (memq :config (cddr (read (current-buffer)))))))
          (should forms)
          (cl-letf (((symbol-function 'org-super-agenda-mode)
                     (lambda (arg) (should (= arg 1)))))
            (dolist (form forms) (eval form t)))))
      (should (equal org-super-agenda-groups expected)))))

(ert-deftest my/org-agenda-style-terminal-keeps-category-labels-without-icons ()
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil))
            ((symbol-function 'find-font)
             (lambda (&rest _) (ert-fail "Terminal styling must not probe GUI fonts"))))
    (should-not (my/org-agenda-category-icons)))
  (my/org-test-workspace
    (my/org-test-append "work.org" "\n* TODO Text-only Work task\n")
    (let ((agenda (my/org-test-agenda "r")))
      (should (string-match-p "Work" agenda))
      (should (string-match-p "TODO" agenda))
      (should (string-match-p "Text-only Work task" agenda)))))

(ert-deftest my/org-agenda-style-gui-icons-are-font-backed-and-match-only-real-categories ()
  (skip-unless (require 'nerd-icons nil t))
  (let (icons)
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
              ((symbol-function 'find-font) (lambda (&rest _) t)))
      (setq icons (my/org-agenda-category-icons)))
    (should (= (length icons) 2))
    (dolist (category '("Work" "Personal"))
      (let* ((entry (seq-find (lambda (entry) (string-match-p (car entry) category)) icons))
             (glyph (car (cadr entry))))
        (should (stringp glyph))
        (should (equal (plist-get (get-text-property 0 'face glyph) :family)
                       (nerd-icons-faicon-family)))))
    (should-not (seq-some (lambda (entry) (string-match-p (car entry) "Other Work")) icons))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
              ((symbol-function 'find-font) (lambda (&rest _) nil)))
      (should-not (my/org-agenda-category-icons)))))

(ert-deftest my/org-agenda-style-date-format-works-for-weekdays-and-year-boundaries ()
  (should (equal (my/org-agenda-format-date '(10 9 2026)) "Friday, 9 October 2026"))
  (should (equal (my/org-agenda-format-date '(1 1 2027)) "Friday, 1 January 2027")))

(ert-deftest my/org-agenda-style-redraw-keeps-row-text-markers-and-modeline ()
  (my/org-test-workspace
    (my/org-test-append "work.org" "\n* DOING Styled work task\n")
    (save-window-excursion
      (org-agenda nil "r")
      (goto-char (point-min)) (search-forward "Styled work task") (beginning-of-line)
      (let* ((before (buffer-string)) (marker (org-get-at-bol 'org-hd-marker))
             (source-file (buffer-file-name (marker-buffer marker)))
             (source-position (marker-position marker))
            (modeline mode-line-format) (cookies (length my/org-agenda-style--face-cookies)))
        (should (markerp marker))
        (should (> cookies 0))
        (my/org-agenda-style-buffer)
        (my/org-agenda-style-buffer)
        (should (equal (buffer-string) before))
        (should (equal marker (org-get-at-bol 'org-hd-marker)))
        (should (equal mode-line-format modeline))
        (should (= (length my/org-agenda-style--face-cookies) cookies))
        (should (equal (window-margins) '(2 . 2)))
        (org-agenda-redo)
        (goto-char (point-min)) (search-forward "Styled work task") (beginning-of-line)
        ;; Org itself replaces its markers on redraw. Check the source target.
        (let ((redrawn-marker (org-get-at-bol 'org-hd-marker)))
          (should (markerp redrawn-marker))
          (should (equal source-file (buffer-file-name (marker-buffer redrawn-marker))))
          (should (= source-position (marker-position redrawn-marker))))))))

(ert-deftest my/org-agenda-style-preserves-overdue-warning-and-all-day-event ()
  (my/org-test-workspace
    (my/org-test-append "work.org"
                        (format "\n* TODO Overdue task\nDEADLINE: <%s>\n* TODO Earlier task\nSCHEDULED: <%s>\n"
                                (my/org-test-date -1) (my/org-test-date -2)))
    (my/org-test-append "calendar-personal.org"
                        (format "\n* All-day styled event\n:org-gcal:\n<%s>\n:END:\n"
                                (my/org-test-date 0)))
    (let ((agenda (my/org-test-agenda "d")))
      (dolist (text '("Overdue task" "Earlier task" "All-day styled event" "TODO" "ago"))
        (should (string-match-p text agenda)))
      (when (featurep 'org-super-agenda)
        (dolist (header '("Events" "Overdue deadlines" "Earlier plans"))
          (should (string-match-p header agenda)))))))

(ert-deftest my/org-agenda-style-does-not-change-non-agenda-buffers-or-source-files ()
  (my/org-test-workspace
    (with-current-buffer (find-file-noselect (my/org-file "personal.org"))
      (let ((text (buffer-string)) (spacing line-spacing) (modeline mode-line-format))
        (my/org-agenda-style-buffer)
        (should (equal (buffer-string) text))
        (should (equal line-spacing spacing))
        (should (equal mode-line-format modeline))
        (should-not my/org-agenda-style--face-cookies)
        (should-not (buffer-modified-p))))))

(ert-deftest my/org-agenda-style-copied-remaps-never-stack-on-redraw ()
  (with-temp-buffer
    (org-agenda-mode)
    (face-remap-add-relative 'org-agenda-date '(:underline t))
    (dotimes (_ 20)
      ;; This is what Org Modern does before our finalization hook.
      (setq-local face-remapping-alist (copy-tree face-remapping-alist))
      (my/org-agenda-style-buffer)
      (dolist (cookie my/org-agenda-style--face-cookies)
        (should (= 1 (cl-count (cdr cookie)
                               (cdr (assq (car cookie) face-remapping-alist))
                               :test #'equal)))))
    (should (member '(:underline t) (cdr (assq 'org-agenda-date face-remapping-alist))))))

(ert-deftest my/org-agenda-style-earlier-later-and-view-changes-never-grow-fonts ()
  (my/org-test-workspace
    (save-window-excursion
      (org-agenda-list nil nil 'day)
      (face-remap-add-relative 'org-agenda-date '(:underline t))
      (text-scale-set 1)
      (let ((initial-cookies (copy-tree my/org-agenda-style--face-cookies)))
        ;; Org keeps face-remapping-alist when it resets the mode. Styling must
        ;; already be stable in the mode hook, not only after finalization.
        (org-agenda-mode)
        (dolist (cookie initial-cookies)
          (should (= 1 (cl-count (cdr cookie)
                                 (cdr (assq (car cookie) face-remapping-alist))
                                 :test #'equal))))
        ;; Restore agenda navigation metadata after the explicit mode reset.
        (org-agenda-list nil nil 'day)
        (dotimes (_ 10)
          (dolist (command '(org-agenda-earlier org-agenda-later))
            ;; The commands used by [ and ] recreate org-agenda-mode.
            (funcall command 1)
            (dolist (cookie initial-cookies)
              (should (= 1 (cl-count (cdr cookie)
                                     (cdr (assq (car cookie) face-remapping-alist))
                                     :test #'equal))))
            (should (= text-scale-mode-amount 1))))
        (org-agenda-change-time-span 'week)
        (org-agenda-change-time-span 'day)
        (org-agenda nil "d")
        (org-agenda nil "r")
        (dolist (cookie initial-cookies)
          (should (= 1 (cl-count (cdr cookie)
                                 (cdr (assq (car cookie) face-remapping-alist))
                                 :test #'equal))))
        (should (member '(:underline t)
                        (cdr (assq 'org-agenda-date face-remapping-alist))))
        (should (= text-scale-mode-amount 1))))))

(ert-deftest my/org-agenda-style-normal-day-and-week-keep-every-row-and-grouping ()
  (my/org-test-workspace
    (my/org-test-append "work.org"
                        (format "\n* TODO Normal planned task\nSCHEDULED: <%s 21:00>\n"
                                (my/org-test-date 0)))
    (my/org-test-append "personal.org"
                        (format "\n* TODO Normal due task\nDEADLINE: <%s>\n"
                                (my/org-test-date 2)))
    (my/org-test-append "calendar-personal.org"
                        (format "\n* Normal timed event\n:org-gcal:\n<%s 16:00-18:00>\n:END:\n* Normal multi-day event\n:org-gcal:\n<%s>--<%s>\n:END:\n"
                                (my/org-test-date 0) (my/org-test-date 0) (my/org-test-date 4)))
    (save-window-excursion
      (dolist (span '(1 7))
        (org-agenda-list nil nil span)
        (let ((text (buffer-string)))
          (dolist (title '("Normal planned task" "Normal due task"
                           "Normal timed event" "Normal multi-day event"))
            (should (string-match-p title text)))
          (should (string-match-p "Day 1 of 5:" text))
          (should (string-match-p "16:00-18:00 +Normal timed event" text))
          (should-not (string-match-p "TODO +\\{3,\\}Normal" text))
          (when (featurep 'org-super-agenda)
            (should (string-match-p "Events" text))
            (should (string-match-p "Work" text))))
        (org-agenda-redo)
        (should (string-match-p "Normal timed event" (buffer-string)))))))

(ert-deftest my/org-agenda-style-column-gaps-are-visual-only ()
  (let ((gap (my/org-agenda-column-gap 14)))
    (should (equal (substring-no-properties gap) " "))
    (should (equal (get-text-property 0 'display gap) '(space :align-to 14))))
  (with-temp-buffer
    (org-mode)
    (insert "* TODO Task\n* Event\n")
    (goto-char (point-min))
    (should (= (get-text-property 0 'my/org-agenda-column (my/org-agenda-heading-gap)) 46))
    (forward-line 1)
    (should (= (get-text-property 0 'my/org-agenda-column (my/org-agenda-heading-gap)) 56))
    (org-agenda-mode)
    (should (equal (my/org-agenda-heading-gap) ""))))

(ert-deftest my/org-agenda-style-times-statuses-states-and-titles-use-fixed-columns ()
  (my/org-test-workspace
    (my/org-test-append "personal.org"
                        (format "\n* TODO Column scheduled task\nSCHEDULED: <%s 21:00>\n* DOING Column future deadline\nDEADLINE: <%s>\n* WAIT Column overdue deadline\nDEADLINE: <%s>\n"
                                (my/org-test-date 0) (my/org-test-date 2) (my/org-test-date -2)))
    (my/org-test-append "calendar-work.org"
                        (format "\n* Column timed event\n<%s 16:00-18:00>\n"
                                (my/org-test-date 0)))
    (my/org-test-append "calendar-personal.org"
                        (format "\n* Column all-day event\n<%s>\n"
                                (my/org-test-date 0)))
    (save-window-excursion
      (dolist (span '(day week))
        (org-agenda-list nil nil span)
        (dolist (title '("Column scheduled task" "Column future deadline"
                         "Column overdue deadline" "Column timed event" "Column all-day event"))
          (goto-char (point-min)) (search-forward title)
          (let* ((title-start (- (point) (length title)))
                 (line-start (line-beginning-position))
                 (heading (text-property-any line-start (line-end-position) 'org-heading t))
                 (state (org-get-at-bol 'todo-state)))
            (should (markerp (org-get-at-bol 'org-hd-marker)))
            (if state
                (progn
                  (should (= (get-text-property (1- heading) 'my/org-agenda-column) 46))
                  ;; Org appends one normal space after the keyword's tab stop.
                  (should (= (get-text-property (- title-start 2) 'my/org-agenda-column) 55)))
              (should (= (get-text-property (1- title-start) 'my/org-agenda-column) 56)))))
        (goto-char (point-min)) (search-forward "16:00-18:00")
        (should (= (get-text-property (- (point) 12) 'my/org-agenda-column) 14))
        (goto-char (point-min)) (search-forward "now ─")
        (let ((now-start (- (point) 5)))
          (should (= (get-text-property (1- now-start) 'my/org-agenda-column) 27))
          (beginning-of-line)
          (should-not (org-get-at-bol 'org-hd-marker))
          (re-search-forward "[0-9][0-9]:[0-9][0-9]")
          (should (= (get-text-property (- (point) 6) 'my/org-agenda-column) 14)))
        (goto-char (point-min)) (search-forward "Column scheduled task")
        (let ((org-log-done nil)) (org-agenda-todo "DOING"))
        (beginning-of-line) (search-forward "Column scheduled task")
        (should (= (get-text-property (- (point) (length "Column scheduled task") 2)
                                     'my/org-agenda-column) 55))))))

(ert-deftest my/org-workflow-refile-moves-instead-of-copying ()
  (my/org-test-workspace
    (my/org-test-append "personal.org" "\n* TODO Move this\nBody\n")
    (let ((target (find-file-noselect (my/org-file "work.org")))
          target-position)
      (with-current-buffer target
        (goto-char (point-min))
        (search-forward "* Tasks")
        (beginning-of-line)
        (setq target-position (point)))
      (with-current-buffer (find-file-noselect (my/org-file "personal.org"))
        (goto-char (point-min))
        (search-forward "* TODO Move this")
        (beginning-of-line)
        (org-refile nil nil (list "Tasks" (my/org-file "work.org") nil target-position))
        (should-not (string-match-p "Move this" (buffer-string))))
      (with-current-buffer target
        (should (string-match-p "\\*\\* TODO Move this" (buffer-string)))
        (should (string-match-p "Body" (buffer-string)))))))

(ert-deftest my/org-calendar-rejects-unconfigured-credentials ()
  (let* ((my/org-calendar-settings-file (make-temp-file "org-calendar-settings-"))
         (my/org-gcal-test-calendar-id nil)
         (org-gcal-client-id nil)
         (org-gcal-client-secret nil))
    (unwind-protect
        (should-error (my/org-calendar-prepare) :type 'user-error)
      (delete-file my/org-calendar-settings-file))))

(ert-deftest my/org-calendar-prepare-maps-only-the-secondary-personal-calendar ()
  (my/org-test-workspace
    (let* ((my/org-calendar-settings-file (make-temp-file "org-calendar-settings-"))
           (my/org-gcal-test-calendar-id "test@group.calendar.google.com")
           (org-gcal-client-id "test-client")
           (org-gcal-client-secret "test-secret")
           (org-gcal-fetch-file-alist nil)
           (org-gcal-auto-archive t)
           (org-gcal-remove-api-cancelled-events t))
      (unwind-protect
          (cl-letf (((symbol-function 'require) (lambda (&rest _) t)))
            (my/org-calendar-prepare)
            (should (equal org-gcal-fetch-file-alist
                           (list (cons my/org-gcal-test-calendar-id
                                       (my/org-file "calendar-personal.org")))))
            (should-not org-gcal-auto-archive)
            (should-not org-gcal-remove-api-cancelled-events)
            (should (equal org-gcal-managed-newly-fetched-mode "gcal")))
        (delete-file my/org-calendar-settings-file)))))

(ert-deftest my/org-calendar-rejects-primary-calendar-during-test ()
  (let* ((my/org-calendar-settings-file (make-temp-file "org-calendar-settings-"))
         (my/org-gcal-test-calendar-id "someone@gmail.com")
         (org-gcal-client-id "test-client")
         (org-gcal-client-secret "test-secret"))
    (unwind-protect
        (should-error (my/org-calendar-prepare) :type 'user-error)
      (delete-file my/org-calendar-settings-file))))

(ert-deftest my/org-calendar-file-and-state-guards ()
  (my/org-test-workspace
    (let ((my/org-gcal-test-calendar-id "test@group.calendar.google.com"))
      (dolist (file '("work.org" "personal.org" "calendar-work.org"))
        (with-current-buffer (find-file-noselect (my/org-file file))
          (goto-char (point-max))
          (insert "\n* An event\n")
          (should-error (my/org-calendar-check-event) :type 'user-error)))
      (with-current-buffer (find-file-noselect (my/org-file "calendar-personal.org"))
        (goto-char (point-max))
        (insert "\n* A local event\n")
        (should-not (my/org-calendar-check-event))
        (org-entry-put (point) "calendar-id" "other@group.calendar.google.com")
        (should-error (my/org-calendar-check-event) :type 'user-error)
        (org-entry-delete (point) "calendar-id")
        (org-todo "DOING")
        (should-error (my/org-calendar-check-event) :type 'user-error)))))

(ert-deftest my/org-calendar-declining-publish-does-not-link-or-post ()
  (my/org-test-workspace
    (let ((my/org-gcal-test-calendar-id "test@group.calendar.google.com"))
      (with-current-buffer (find-file-noselect (my/org-file "calendar-personal.org"))
        (goto-char (point-max))
        (insert "\n* An event\n")
        (cl-letf (((symbol-function 'my/org-calendar-prepare) #'ignore)
                  ((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
                  ((symbol-function 'org-gcal-post-at-point)
                   (lambda (&rest _) (ert-fail "Unexpected Google write"))))
          (my/org-calendar-publish)
          (should-not (org-entry-get (point) "calendar-id")))))))

(ert-deftest my/org-calendar-fetch-never-calls-bidirectional-sync ()
  (let ((my/org-calendar-access-token "test-token")
        (my/org-calendar-token-expiration (+ (float-time) 3600)) fetched)
    (cl-letf (((symbol-function 'my/org-calendar-prepare) #'ignore)
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
              ((symbol-function 'org-gcal-fetch) (lambda () (setq fetched t)))
              ((symbol-function 'org-gcal-sync)
               (lambda (&rest _) (ert-fail "Unexpected bulk sync"))))
      (my/org-calendar-fetch)
      (should fetched))))

(ert-deftest my/org-calendar-fetch-without-login-does-not-start-sync ()
  (let ((my/org-calendar-access-token nil)
        (my/org-calendar-token-expiration nil))
    (cl-letf (((symbol-function 'my/org-calendar-prepare) #'ignore)
              ((symbol-function 'org-gcal-fetch)
               (lambda () (ert-fail "Sync must not start before login"))))
      (should-error (my/org-calendar-fetch) :type 'user-error))))

(ert-deftest my/org-calendar-login-filter-handles-split-output-privately ()
  (let ((process (make-pipe-process :name "org-calendar-test-protocol" :buffer nil :noquery t))
        (my/org-calendar-access-token nil)
        (my/org-calendar-token-expiration nil) opened)
    (set-process-buffer process nil)
    (unwind-protect
        (cl-letf (((symbol-function 'my/org-calendar-open-auth-url)
                   (lambda (url) (setq opened url))))
          (my/org-calendar-login-filter process "ORG-CALENDAR URL \"https://example.test/authorize\"\nORG-CALENDAR TO")
          (should (equal opened "https://example.test/authorize"))
          (should-not my/org-calendar-access-token)
          (my/org-calendar-login-filter
           process (format "KEN {\"token\":\"fake-private-token\",\"expiration\":%d}\n" (+ (floor (float-time)) 3600)))
          (should (equal my/org-calendar-access-token "fake-private-token"))
          (should (process-get process 'authenticated))
          (should-not (process-buffer process))
          (should (equal (process-get process 'pending) "")))
      (delete-process process))))

(ert-deftest my/org-calendar-login-can-be-cancelled-without-editor-sync ()
  (let* ((process (make-pipe-process :name "org-calendar-test-cancel" :buffer nil :noquery t))
         (my/org-calendar-login-process process)
         (my/org-calendar-access-token nil)
         (my/org-calendar-token-expiration nil))
    (set-process-sentinel process #'my/org-calendar-login-sentinel)
    (my/org-calendar-stop-login)
    (should (process-get process 'stopped))
    (should-not (process-live-p process))
    (should-not my/org-calendar-login-process)))

(ert-deftest my/org-calendar-worker-encrypts-and-reads-tokens-in-a-separate-process ()
  (skip-unless (and (locate-library "org-gcal") (executable-find "gpg")))
  (let* ((directory (make-temp-file "org-calendar-worker-test-" t))
         (settings (expand-file-name "settings.el" directory))
         (store (expand-file-name "tokens.plist" directory))
         (input (expand-file-name "test-input" directory))
         ;; Fake authorization: exercise real worker IPC and GPG, without Google.
         (setup '(progn
                   (require 'org-gcal)
                   (defun oauth2-auto-plist (user provider)
                     (let* ((data (or (oauth2-auto--plstore-read user provider)
                                      (oauth2-auto--plstore-write
                                       user provider
                                       (list :access-token "fake-worker-token"
                                             :expiration (+ (floor (float-time)) 3600)))))
                            (promise (aio-promise)))
                       (aio-resolve promise (lambda () data))
                       promise)))))
    (unwind-protect
        (progn
          (write-region "(setq my/org-gcal-test-calendar-id \"test@group.calendar.google.com\")\n"
                        nil settings nil 'silent)
          (write-region "fake-test-passphrase\n" nil input nil 'silent)
          (dotimes (_ 2)
            (with-temp-buffer
              (should (= 0 (call-process
                            (expand-file-name invocation-name invocation-directory)
                            input t nil "-Q" "--batch" "--eval"
                            (prin1-to-string `(setq load-path ',load-path))
                            "--eval" (prin1-to-string setup)
                            "-l" my/org-calendar-test-worker-file "--" settings store)))
              (should (string-match-p "ORG-CALENDAR TOKEN " (buffer-string)))
              (should-not (string-match-p "fake-test-passphrase" (buffer-string)))))
          (with-temp-buffer
            (insert-file-contents store)
            (should (string-match-p "BEGIN PGP MESSAGE" (buffer-string)))
            (should-not (string-match-p "fake-worker-token\\|fake-test-passphrase" (buffer-string))))
          (should (= (logand (file-modes store) #o777) #o600)))
      (delete-directory directory t))))

(ert-deftest my/org-calendar-login-returns-immediately-and-times-out ()
  (let* ((directory (make-temp-file "org-calendar-background-test-" t))
         (my/org-calendar-auth-worker-file (expand-file-name "worker.el" directory))
         (my/org-calendar-settings-file (expand-file-name "settings.el" directory))
         (oauth2-auto-plstore (expand-file-name "tokens.plist" directory))
         (my/org-calendar-login-process nil)
         (my/org-calendar-access-token nil)
         (my/org-calendar-token-expiration nil)
         (my/org-calendar-token-passphrase nil)
         (my/org-calendar-auth-problem nil)
         (my/org-calendar-auth-retry-after 0)
         (my/org-calendar-token-passphrase nil)
         (my/org-calendar-auth-problem nil)
         (my/org-calendar-auth-retry-after 0)
         (schedule (symbol-function 'run-at-time))
         responsive started)
    (unwind-protect
        (progn
          (write-region "(read-string \"\")\n(sleep-for 120)\n"
                        nil my/org-calendar-auth-worker-file nil 'silent)
          (cl-letf (((symbol-function 'my/org-calendar-prepare) #'ignore)
                    ((symbol-function 'read-passwd) (lambda (&rest _) (copy-sequence "fake-passphrase")))
                    ((symbol-function 'run-at-time)
                     (lambda (_time repeat function &rest args)
                       (apply schedule 0.15 repeat function args))))
            (setq started (float-time))
            (my/org-calendar-login)
            (should (< (- (float-time) started) 1))
            (should (process-live-p my/org-calendar-login-process))
            (should-not (process-buffer my/org-calendar-login-process))
            (funcall schedule 0.01 nil (lambda () (setq responsive t)))
            (let ((deadline (+ (float-time) 3)))
              (while (and my/org-calendar-login-process (< (float-time) deadline))
                (accept-process-output nil 0.05)))
            (should responsive)
            (should-not my/org-calendar-login-process)))
      (when (and my/org-calendar-login-process (process-live-p my/org-calendar-login-process))
        (my/org-calendar-stop-login))
      (delete-directory directory t))))

(ert-deftest my/org-calendar-worker-sends-auth-link-while-still-waiting ()
  (skip-unless (locate-library "org-gcal"))
  (let* ((directory (make-temp-file "org-calendar-link-test-" t))
         (settings (expand-file-name "settings.el" directory))
         (store (expand-file-name "tokens.plist" directory))
         (output "") process
         (setup '(with-eval-after-load 'org-gcal
                   ;; A pending fake login: no real Google request is sent.
                   (defun oauth2-auto-plist (&rest _)
                     (funcall browse-url-browser-function "https://example.test/authorize")
                     (aio-promise)))))
    (unwind-protect
        (progn
          (write-region "(setq my/org-gcal-test-calendar-id \"test@group.calendar.google.com\")\n"
                        nil settings nil 'silent)
          (setq process
                (make-process
                 :name "org-calendar-test-link" :noquery t :connection-type 'pipe
                 :command (list (expand-file-name invocation-name invocation-directory)
                                "-Q" "--batch" "--eval"
                                (prin1-to-string `(setq load-path ',load-path))
                                "--eval" (prin1-to-string setup)
                                "-l" my/org-calendar-test-worker-file "--" settings store)
                 :filter (lambda (_ text) (setq output (concat output text)))))
          (process-send-string process "fake-test-passphrase\n")
          (let ((deadline (+ (float-time) 5)))
            (while (and (not (string-match-p "ORG-CALENDAR URL " output))
                        (process-live-p process) (< (float-time) deadline))
              (accept-process-output process 0.05)))
          (should (string-match-p "ORG-CALENDAR URL \"https://example.test/authorize\"" output))
          (should (process-live-p process))
          (should-not (string-match-p "fake-test-passphrase" output))
          (should-not (file-exists-p store)))
      (when (and process (process-live-p process)) (delete-process process))
      (delete-directory directory t))))

(ert-deftest my/org-calendar-background-worker-never-opens-a-browser ()
  (skip-unless (locate-library "org-gcal"))
  (let* ((directory (make-temp-file "org-calendar-refresh-test-" t))
         (settings (expand-file-name "settings.el" directory))
         (input (expand-file-name "fake-input" directory))
         (setup '(with-eval-after-load 'org-gcal
                    (defun oauth2-auto--browser-request (&rest _) (princ "UNSAFE-BROWSER-CALL"))
                    (defun oauth2-auto--plstore-read (&rest _)
                      '(:refresh-token "fake-refresh-token"))
                    (defun oauth2-auto-refresh (&rest _) (oauth2-auto--browser-request)))))
    (unwind-protect
        (progn
          (write-region "(setq my/org-gcal-test-calendar-id \"test@group.calendar.google.com\")\n"
                        nil settings nil 'silent)
          (write-region "fake-passphrase\n" nil input nil 'silent)
          (with-temp-buffer
            (should (= 1 (call-process
                          (expand-file-name invocation-name invocation-directory)
                          input t nil "-Q" "--batch" "--eval"
                          (prin1-to-string `(setq load-path ',load-path))
                          "--eval" (prin1-to-string setup)
                          "-l" my/org-calendar-test-worker-file "--" settings
                          (expand-file-name "tokens.plist" directory) "refresh-only")))
            (should (string-match-p "ORG-CALENDAR ERROR" (buffer-string)))
            (should-not (string-match-p "UNSAFE-BROWSER-CALL\\|ORG-CALENDAR URL\\|fake-passphrase" (buffer-string)))))
      (delete-directory directory t))))

(ert-deftest my/org-calendar-worker-renews-near-expiry-and-forces-background-refresh ()
  (skip-unless (and (locate-library "org-gcal") (executable-find "gpg")))
  (dolist (case '((30 nil) (3600 "refresh-only")))
    (let* ((directory (make-temp-file "org-calendar-renew-test-" t))
           (settings (expand-file-name "settings.el" directory))
           (input (expand-file-name "fake-input" directory))
           (store (expand-file-name "tokens.plist" directory))
           (setup `(with-eval-after-load 'org-gcal
                     (defun oauth2-auto--plstore-read (&rest _)
                       (list :access-token "fake-old-token" :refresh-token "fake-refresh-token"
                             :expiration (+ (float-time) ,(car case))))
                     (defun oauth2-auto--request (&rest _)
                       (my/org-calendar-worker-send "TEST REFRESH RAN")
                       (let ((promise (aio-promise)))
                         (aio-resolve promise
                                      (lambda () '((access_token . "fake-renewed-token") (expires_in . 3600))))
                         promise))
                     (defun oauth2-auto-authenticate (&rest _) (error "Unexpected browser login")))))
      (unwind-protect
          (progn
            (write-region "(setq my/org-gcal-test-calendar-id \"test@group.calendar.google.com\")\n"
                          nil settings nil 'silent)
            (write-region "fake-passphrase\n" nil input nil 'silent)
            (with-temp-buffer
              (should (= 0 (apply #'call-process
                                  (expand-file-name invocation-name invocation-directory)
                                  input t nil
                                  (append (list "-Q" "--batch" "--eval"
                                                (prin1-to-string `(setq load-path ',load-path))
                                                "--eval" (prin1-to-string setup)
                                                "-l" my/org-calendar-test-worker-file "--" settings store)
                                          (when (cadr case) (list (cadr case)))))))
              (should (string-match-p "TEST REFRESH RAN" (buffer-string)))
              (should (string-match-p "ORG-CALENDAR TOKEN.*fake-renewed-token" (buffer-string)))
              (should-not (string-match-p "ORG-CALENDAR URL\\|fake-passphrase\\|fake-refresh-token" (buffer-string))))
            (with-temp-buffer
              (insert-file-contents store)
              (should (string-match-p "BEGIN PGP MESSAGE" (buffer-string)))
              (should-not (string-match-p "fake-renewed-token\\|fake-passphrase\\|fake-refresh-token" (buffer-string)))))
        (delete-directory directory t)))))

(ert-deftest my/org-calendar-worker-distinguishes-network-and-revoked-access ()
  (skip-unless (locate-library "org-gcal"))
  (dolist (case '(("temporary" "temporarily_unavailable") ("authorization" "invalid_grant")))
    (let* ((directory (make-temp-file "org-calendar-error-test-" t))
           (settings (expand-file-name "settings.el" directory))
           (input (expand-file-name "fake-input" directory))
           (setup `(with-eval-after-load 'org-gcal
                     (defun oauth2-auto--plstore-read (&rest _)
                       '(:refresh-token "fake-private-refresh-token"))
                     (defun oauth2-auto--request-access-parse () '((error . ,(cadr case))))
                     (defun oauth2-auto-refresh (&rest _)
                       (oauth2-auto--request-access-parse)
                       (error "Sensitive dependency error: fake-private-refresh-token"))
                     (defun oauth2-auto-authenticate (&rest _) (princ "UNSAFE-BROWSER-CALL")))))
      (unwind-protect
          (progn
            (write-region "(setq my/org-gcal-test-calendar-id \"test@group.calendar.google.com\")\n"
                          nil settings nil 'silent)
            (write-region "fake-passphrase\n" nil input nil 'silent)
            (with-temp-buffer
              (should (= 1 (call-process
                            (expand-file-name invocation-name invocation-directory)
                            input t nil "-Q" "--batch" "--eval"
                            (prin1-to-string `(setq load-path ',load-path))
                            "--eval" (prin1-to-string setup)
                            "-l" my/org-calendar-test-worker-file "--" settings
                            (expand-file-name "tokens.plist" directory) "refresh-only")))
              (should (string-match-p (concat "ORG-CALENDAR ERROR " (car case)) (buffer-string)))
              (should-not (string-match-p "UNSAFE-BROWSER-CALL\\|ORG-CALENDAR URL\\|fake-private-refresh-token\\|fake-passphrase"
                                          (buffer-string)))))
        (delete-directory directory t)))))

(ert-deftest my/org-calendar-background-failures-preserve-unlock-except-for-bad-passphrase ()
  (dolist (failure '(temporary authorization unlock))
    (let* ((process (make-pipe-process :name "calendar-failure-test" :buffer nil :noquery t))
           (my/org-calendar-login-process process)
           (my/org-calendar-token-passphrase (copy-sequence "fake-unlock"))
           (my/org-calendar-access-token nil)
           (my/org-calendar-token-expiration nil)
           (my/org-calendar-auth-problem nil)
           (my/org-calendar-auth-retry-after 0)
           (my/org-calendar-auth-finished-hook nil))
      (process-put process 'background t)
      (my/org-calendar-login-filter process (format "ORG-CALENDAR ERROR %s\n" failure))
      (delete-process process)
      (cl-letf (((symbol-function 'my/org-calendar-show-login-status)
                 (lambda (&rest _) (ert-fail "Background refresh must stay quiet"))))
        (my/org-calendar-login-sentinel process "finished"))
      (should (eq my/org-calendar-auth-problem failure))
      (should-not my/org-calendar-login-process)
      (if (eq failure 'unlock) (should-not my/org-calendar-token-passphrase)
        (should (equal my/org-calendar-token-passphrase "fake-unlock")))
      (when (eq failure 'temporary)
        (should (> my/org-calendar-auth-retry-after (float-time)))))))

(ert-deftest my/org-calendar-background-refresh-retries-without-another-passphrase-prompt ()
  (let ((my/org-calendar-token-passphrase (copy-sequence "fake-unlock"))
        (my/org-calendar-auth-problem 'temporary)
        (my/org-calendar-auth-retry-after (+ (float-time) 60))
        (my/org-calendar-login-process nil) launched)
    (cl-letf (((symbol-function 'read-passwd) (lambda (&rest _) (ert-fail "Repeated passphrase prompt")))
              ((symbol-function 'my/org-calendar--launch-login)
               (lambda (passphrase background) (setq launched (list passphrase background)))))
      (my/org-calendar-background-refresh)
      (should-not launched)
      (setq my/org-calendar-auth-retry-after 0)
      (my/org-calendar-background-refresh)
      (should (equal launched '("fake-unlock" t)))
      (setq launched nil my/org-calendar-auth-problem 'authorization)
      (my/org-calendar-background-refresh)
      (should-not launched))))

(ert-deftest my/org-calendar-google-reauthorization-reuses-the-local-unlock ()
  (let ((my/org-calendar-token-passphrase (copy-sequence "fake-unlock"))
        (my/org-calendar-auth-problem 'authorization)
        (my/org-calendar-auth-retry-after 0)
        (my/org-calendar-login-process nil)
        (my/org-calendar-access-token nil)
        (my/org-calendar-token-expiration nil) launched)
    (cl-letf (((symbol-function 'my/org-calendar-prepare) #'ignore)
              ((symbol-function 'file-readable-p) (lambda (_) t))
              ((symbol-function 'read-passwd) (lambda (&rest _) (ert-fail "Unlock is already valid")))
              ((symbol-function 'my/org-calendar-show-login-status) #'ignore)
              ((symbol-function 'my/org-calendar--launch-login)
               (lambda (passphrase &optional background)
                 (setq launched (list (copy-sequence passphrase) background)))))
      (my/org-calendar-login)
      (should (equal launched '("fake-unlock" nil)))
      (should (equal my/org-calendar-token-passphrase "fake-unlock"))
      (should-not my/org-calendar-auth-problem))))

(ert-deftest my/org-calendar-publish-links-only-after-confirmation ()
  (my/org-test-workspace
    (let ((my/org-gcal-test-calendar-id "test@group.calendar.google.com") posted)
      (with-current-buffer (find-file-noselect (my/org-file "calendar-personal.org"))
        (goto-char (point-max))
        (insert "\n* An event\n:org-gcal:\n<2026-10-09 Fri 10:00-11:00>\n:END:\n")
        (org-back-to-heading t)
        (cl-letf (((symbol-function 'my/org-calendar-prepare) #'ignore)
                  ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                  ((symbol-function 'org-gcal-post-at-point) (lambda () (setq posted t))))
          (my/org-calendar-publish)
          (should posted)
          (should (equal (org-entry-get (point) "calendar-id") my/org-gcal-test-calendar-id)))))))

(ert-deftest my/org-calendar-publish-works-from-an-agenda-source-marker ()
  (my/org-test-workspace
    (my/org-test-append "calendar-personal.org"
                        (format "\n* Agenda appointment\n:org-gcal:\n<%s 10:00-11:00>\n:END:\n"
                                (my/org-test-date 0)))
    (let ((my/org-gcal-test-calendar-id "test@group.calendar.google.com") posted)
      (save-window-excursion
        (org-agenda nil "d")
        (goto-char (point-min))
        (search-forward "Agenda appointment")
        (cl-letf (((symbol-function 'my/org-calendar-prepare) #'ignore)
                  ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                  ((symbol-function 'org-gcal-post-at-point) (lambda () (setq posted t))))
          (my/org-calendar-publish)
          (should posted))))))

(ert-deftest my/org-calendar-cannot-cancel-an-unlinked-event ()
  (my/org-test-workspace
    (let ((my/org-gcal-test-calendar-id "test@group.calendar.google.com"))
      (with-current-buffer (find-file-noselect (my/org-file "calendar-personal.org"))
        (goto-char (point-max))
        (insert "\n* An event\n")
        (cl-letf (((symbol-function 'my/org-calendar-prepare) #'ignore)
                  ((symbol-function 'org-gcal-delete-at-point)
                   (lambda (&rest _) (ert-fail "Unexpected deletion"))))
          (should-error (my/org-calendar-cancel) :type 'user-error))))))
