;;; org-calendar-status-test.el --- Context and mouse-control regressions -*- lexical-binding: t; -*-
(unless (featurep 'org-calendar-auto)
  (load (expand-file-name "org-calendar-auto-test.el" (file-name-directory load-file-name)) nil t))

(defmacro my/calendar-status-test-state (&rest body)
  (declare (indent 0))
  `(let ((org-directory "/disposable/org/")
         (my/org-calendar-auto--file "/disposable/org/calendar-personal.org")
         (my/org-calendar-auto-mode t)
         (my/org-calendar-auto-status "up to date")
         (my/org-calendar-auto--last-error nil)
         (my/org-calendar-auth-problem nil)
         (my/org-calendar-login-process nil)
         (my/org-calendar-keychain-enabled nil))
     (with-temp-buffer ,@body)))

(ert-deftest my/calendar-status-healthy-and-routine-pending-hide-outside-calendar ()
  (my/calendar-status-test-state
    (should-not (my/org-calendar-status-render))
    (setq my/org-calendar-auto-status "pending")
    (should-not (my/org-calendar-status-render))
    (setq my/org-calendar-auto-mode nil my/org-calendar-auto-status "paused")
    (should-not (my/org-calendar-status-render))))

(ert-deftest my/calendar-status-context-includes-agenda-week-and-both-calendar-files ()
  (my/calendar-status-test-state
    (dolist (mode '(org-agenda-mode org-timegrid-mode))
      (setq major-mode mode)
      (should (my/org-calendar-status-render)))
    (setq major-mode 'org-mode)
    (dolist (file '("calendar-personal.org" "calendar-work.org"))
      (setq buffer-file-name (expand-file-name file org-directory))
      (should (my/org-calendar-status-render)))
    (setq buffer-file-name (expand-file-name "personal.org" org-directory))
    (should-not (my/org-calendar-status-render))
    (setq buffer-file-name "/another/directory/calendar-personal.org")
    (should-not (my/org-calendar-status-render))))

(ert-deftest my/calendar-status-conflicts-login-and-failed-retries-stay-visible-everywhere ()
  (my/calendar-status-test-state
    (dolist (status '("needs login" "needs attention"))
      (setq my/org-calendar-auto-status status)
      (should (my/org-calendar-status-render)))
    (setq my/org-calendar-auto-status "pending"
          my/org-calendar-auto--last-error "Offline; changes kept")
    (should (equal (my/org-calendar-status-state) "retrying"))
    (should (string-match-p "Offline; changes kept"
                            (get-text-property 0 'help-echo (my/org-calendar-status-render))))
    (setq my/org-calendar-auto--last-error nil my/org-calendar-auth-problem 'temporary)
    (should (my/org-calendar-status-render))))

(ert-deftest my/calendar-status-all-states-have-readable-tooltips-and-mouse-bindings ()
  (my/calendar-status-test-state
    (setq major-mode 'org-agenda-mode)
    (dolist (entry my/org-calendar-status-icons)
      (setq my/org-calendar-auto-status (car entry)
            my/org-calendar-auto-mode (not (equal (car entry) "paused")))
      (let* ((text (my/org-calendar-status-render))
             (map (get-text-property 0 'local-map text)))
        (should (string-match-p (regexp-quote (nth 4 entry)) (get-text-property 0 'help-echo text)))
        (should (eq (lookup-key map [mode-line mouse-1]) #'my/org-calendar-status-open))
        (should (eq (lookup-key map [mode-line mouse-3]) #'my/org-calendar-status-menu))))))

(ert-deftest my/calendar-status-paused-icon-remains-available-in-calendar-context ()
  (my/calendar-status-test-state
    (setq major-mode 'org-agenda-mode my/org-calendar-auto-mode nil)
    (should (equal (my/org-calendar-status-state) "paused"))
    (should (string-match-p "Paused" (get-text-property 0 'help-echo (my/org-calendar-status-render))))))

(ert-deftest my/calendar-status-terminal-fallback-does-not-probe-fonts ()
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil))
            ((symbol-function 'find-font) (lambda (&rest _) (ert-fail "Do not probe terminal fonts"))))
    (dolist (entry my/org-calendar-status-icons)
      (should (equal (substring-no-properties (my/org-calendar-status-icon entry)) (nth 2 entry))))))

(ert-deftest my/calendar-status-left-click-uses-existing-status-command ()
  (let (opened)
    (cl-letf (((symbol-function 'my/org-calendar-auto-review) (lambda () (setq opened t))))
      (my/org-calendar-status-open)
      (should opened))))

(ert-deftest my/calendar-status-menu-reuses-commands-and-disables-unsafe-paused-sync ()
  (my/calendar-status-test-state
    (dolist (enabled '(t nil))
      (setq my/org-calendar-auto-mode enabled)
      (let* ((map (my/org-calendar-status-menu-map))
             (more (lookup-key map [more]))
             (sync (cdr (assq 'sync (cdr more))))
             (pause (cdr (assq 'pause (cdr more)))))
        (should (eq (lookup-key map [status]) #'my/org-calendar-auto-review))
        (should (eq (nth 2 pause) #'my/org-calendar-auto-mode))
        (should (equal (nth 1 pause) (if enabled "Pause automatic sync" "Resume automatic sync")))
        (should (eq (nth 2 sync) #'my/org-calendar-fetch))
        (should (eq (plist-get (nthcdr 3 sync) :enable) enabled))))))

(ert-deftest my/calendar-status-install-is-idempotent-and-preserves-other-modeline-items ()
  (let ((global-mode-string '("Other indicator"
                              (:eval (when my/org-calendar-auto-mode
                                       (concat " Cal: " my/org-calendar-auto-status))))))
    (my/org-calendar-status-install)
    (my/org-calendar-status-install)
    (should (member "Other indicator" global-mode-string))
    (should (= 1 (cl-count my/org-calendar-status-mode-line global-mode-string :test #'equal)))
    (should (= 2 (length global-mode-string)))))

(ert-deftest my/calendar-status-network-failure-has-a-visible-retry-reason ()
  (my/calendar-status-test-state
    (cl-letf (((symbol-function 'my/org-calendar-auto--finish)
               (lambda (status) (setq my/org-calendar-auto-status status))))
      (my/org-calendar-auto--failure nil)
      (should (equal my/org-calendar-auto-status "pending"))
      (should (equal (my/org-calendar-status-state) "retrying"))
      (should (my/org-calendar-status-render))
      (should (string-match-p "could not be reached" my/org-calendar-auto--last-error)))))

(ert-deftest my/calendar-status-rendering-and-opening-menu-never-sync-or-save ()
  (my/calendar-status-test-state
    (setq major-mode 'org-agenda-mode)
    (let (shown)
      (cl-letf (((symbol-function 'my/org-calendar-auto--request)
                 (lambda (&rest _) (ert-fail "Status UI must not issue calendar requests")))
                ((symbol-function 'save-buffer)
                 (lambda (&rest _) (ert-fail "Status UI must not save source buffers")))
                ((symbol-function 'popup-menu)
                 (lambda (map &optional _) (setq shown (keymapp map)))))
        (should (my/org-calendar-status-render))
        (my/org-calendar-status-menu)
        (should shown)))))
