;;; org-sync-ui-test.el --- Shared sync controls without live data -*- lexical-binding: t; -*-
(require 'ert)
(unless (featurep 'org-calendar-auto)
  (load (expand-file-name "org-calendar-auto-test.el" (file-name-directory load-file-name)) nil t))
(load (expand-file-name "../lisp/org-sync-ui.el" (file-name-directory load-file-name)) nil t)

(defconst my/sync-ui-test-calendar-request (symbol-function 'my/org-calendar-auto--request))
(defconst my/sync-ui-test-config
  (expand-file-name "../config.org" (file-name-directory load-file-name)))

(defmacro my/sync-ui-test-state (&rest body)
  (declare (indent 0))
  `(let ((my/org-calendar-auto-mode t) (my/org-calendar-auto-status "up to date")
         (my/org-calendar-auto--file "/disposable/calendar-personal.org")
         (my/org-calendar-auto--busy nil) (my/org-calendar-auto--last-error nil)
         (my/org-calendar-auto--last-run nil) (my/org-calendar-auto--last-success nil)
         (my/org-calendar-auth-problem nil) (my/org-calendar-login-process nil)
         (my/org-calendar-keychain-enabled nil)
         (my/org-calendar-repeat--pending nil))
     (with-temp-buffer ,@body)))

(ert-deftest my/sync-ui-badge-keeps-its-name-and-click-target ()
  (my/sync-ui-test-state
    (setq major-mode 'org-agenda-mode my/org-calendar-auto-status "needs attention")
    (let* ((text (my/org-sync-ui-render))
           (calendar-map (get-text-property (string-match "Cal" text) 'local-map text))
           opened)
      (should (string-match-p (regexp-quote "[Cal !]") text))
      (should-not (string-match-p "Tasks" text))
      (cl-letf (((symbol-function 'my/org-sync-open) (lambda (kind) (push kind opened))))
        (funcall (lookup-key calendar-map [mode-line mouse-1]) nil))
      (should (equal opened '(calendar))))))

(ert-deftest my/sync-ui-healthy-badge-hides-outside-context-and-problems-show-it ()
  (my/sync-ui-test-state
    (should-not (my/org-sync-ui-render))
    (setq my/org-calendar-auto-status "needs login")
    (should (string-match-p "Cal" (my/org-sync-ui-render)))
    (setq my/org-calendar-auto-status "up to date")
    (should-not (my/org-sync-ui-render))
    (setq major-mode 'org-agenda-mode)
    (should (string-match-p "Cal ✓" (my/org-sync-ui-render)))
    (setq my/org-calendar-auto-mode nil)
    (should (string-match-p "Cal Ⅱ" (my/org-sync-ui-render)))))

(ert-deftest my/sync-ui-distinguishes-syncing-unsaved-queued-and-retrying ()
  (my/sync-ui-test-state
    (setq my/org-calendar-auto-status "pending")
    (should (eq (plist-get (my/org-sync-ui--snapshot 'calendar) :state) 'waiting))
    (cl-letf (((symbol-function 'my/org-sync-ui--source-modified-p) (lambda (_) t)))
      (should (eq (plist-get (my/org-sync-ui--snapshot 'calendar) :state) 'unsaved))
      (should (string-match-p "Save calendar-personal.org" (plist-get (my/org-sync-ui--snapshot 'calendar) :reason)))
      (setq my/org-calendar-auto--busy t)
      (should (eq (plist-get (my/org-sync-ui--snapshot 'calendar) :state) 'syncing)))
    (setq my/org-calendar-auto--busy nil my/org-calendar-auto--last-error "Offline; changes kept")
    (should (eq (plist-get (my/org-sync-ui--snapshot 'calendar) :state) 'retrying))
    (should (string-match-p "automatically" (my/org-sync-ui--tooltip 'calendar)))))

(ert-deftest my/sync-ui-unconfigured-errors-still-have-a-visible-explanation ()
  (my/sync-ui-test-state
    (setq my/org-calendar-auto--file nil my/org-calendar-auto-mode nil
          my/org-calendar-auto--last-error "Private approval could not be read")
    (should (eq (plist-get (my/org-sync-ui--snapshot 'calendar) :state) 'error))
    (should (my/org-sync-ui-render))))

(ert-deftest my/sync-ui-before-org-load-explains-lazy-startup-without-starting-sync ()
  (my/sync-ui-test-state
    (let ((original-featurep (symbol-function 'featurep)))
      (cl-letf (((symbol-function 'featurep)
                 (lambda (feature &optional subfeature)
                   (unless (eq feature 'org-calendar-auto)
                     (funcall original-featurep feature subfeature)))))
        (setq my/org-calendar-auto--file nil)
        (should (eq (plist-get (my/org-sync-ui--snapshot 'calendar) :state) 'unloaded))
        (should (string-match-p "Open your Org agenda"
                                (plist-get (my/org-sync-ui--snapshot 'calendar) :reason)))))))

(ert-deftest my/sync-ui-hover-is-selective-and-preserves-unrelated-help ()
  (my/sync-ui-test-state
    (let* ((my/org-sync-ui--tooltip-active nil) tips other-help
          (my/org-sync-ui--previous-help-function (lambda (help) (push help other-help))))
      (cl-letf (((symbol-function 'tooltip-show-help) (lambda (help) (push help tips))))
        (my/org-sync-ui--show-help "Unrelated help")
        (should-not tips)
        (let ((help (my/org-sync-ui--tooltip 'calendar)))
          (should (get-text-property 0 'my/org-sync-tooltip help))
          (should (string-match-p "Personal Calendar" help))
          (should (string-match-p "Not recorded this session" help))
          (my/org-sync-ui--show-help help))
        (should my/org-sync-ui--tooltip-active)
        (my/org-sync-ui--show-help nil)
        (should-not my/org-sync-ui--tooltip-active)
        (should-not (car tips))
        (should (equal other-help '(nil "Unrelated help")))))))

(ert-deftest my/sync-ui-opening-rendering-and-refreshing-never-sync-save-or-login ()
  (my/sync-ui-test-state
    (cl-letf (((symbol-function 'request) (lambda (&rest _) (ert-fail "No network from UI")))
              ((symbol-function 'save-buffer) (lambda (&rest _) (ert-fail "No source saves from UI")))
              ((symbol-function 'write-region) (lambda (&rest _) (ert-fail "No cache writes from UI")))
              ((symbol-function 'find-file-noselect) (lambda (&rest _) (ert-fail "Do not open source files")))
              ((symbol-function 'my/org-calendar-auto--schedule) (lambda (&rest _) (ert-fail "No implicit sync")))
              ((symbol-function 'my/org-calendar-login) (lambda (&rest _) (ert-fail "No implicit sign-in")))
              ((symbol-function 'pop-to-buffer) (lambda (buffer &rest _) buffer)))
      (unwind-protect
          (progn
            (my/org-sync-open 'calendar)
            (with-current-buffer my/org-sync-ui--buffer
              (should (eq my/org-sync-ui--selected 'calendar))
              (should (string-match-p "Calendar" (buffer-string)))
              (should-not (string-match-p "Tasks" (buffer-string)))
              (should (string-match-p "Last successful sync" (buffer-string)))
              (my/org-sync-ui-refresh)
              (my/org-sync-ui-render)
              (my/org-sync-ui--tooltip 'calendar)))
        (when (get-buffer my/org-sync-ui--buffer) (kill-buffer my/org-sync-ui--buffer))))))

(ert-deftest my/sync-ui-keychain-controls-are-in-the-panel-without-task-links ()
  (my/sync-ui-test-state
    (my/org-sync-ui-mode)
    (my/org-sync-ui-refresh)
    (dolist (label '("Keychain unlock" "Set up / update" "Forget unlock..."))
      (should (string-match-p (regexp-quote label) (buffer-string))))
    (should-not (string-match-p "Tasks\\|time-block\\|Link\\.\\.\\." (buffer-string)))
    (should (string-match-p "Not enabled" (buffer-string)))
    (setq my/org-calendar-keychain-enabled t)
    (my/org-sync-ui-refresh)
    (should (string-match-p "Keychain unlock: Enabled" (buffer-string)))))

(ert-deftest my/sync-ui-keychain-buttons-only-call-the-chosen-confirmed-action ()
  (my/sync-ui-test-state
    (let (calls)
      (cl-letf (((symbol-function 'my/org-calendar-keychain-enable) (lambda () (push 'setup calls)))
                ((symbol-function 'my/org-calendar-keychain-disable) (lambda () (push 'forget calls))))
        (my/org-sync-ui--act 'keychain 'calendar)
        (should (equal calls '(setup)))
        (my/org-sync-ui--act 'keychain-forget 'calendar)
        (should (equal calls '(forget setup)))))))

(ert-deftest my/sync-ui-keychain-completion-refreshes-even-with-sync-paused ()
  (let (callback completed refreshed)
    (cl-letf (((symbol-function 'my/org-sync-ui--changed) (lambda (&rest _) (setq refreshed t))))
      (my/org-sync-ui--keychain-process
       (lambda (operation passphrase done)
         (should (equal operation "put"))
         (should (equal passphrase "fake-unlock"))
         (setq callback done))
       "put" "fake-unlock" (lambda (success) (setq completed success)))
      (should-not refreshed)
      (funcall callback t)
      (should completed)
      (should refreshed))))

(ert-deftest my/sync-ui-config-clears-retired-prefixes-and-keeps-integrations-and-week ()
  (with-temp-buffer
    (insert-file-contents my/sync-ui-test-config)
    (goto-char (point-min))
    (search-forward "(map! :leader\n      \"n g\" nil")
    (goto-char (match-beginning 0))
    (let ((form (read (current-buffer))))
      (should (equal (cl-subseq form 2 6) '("n g" nil "n T" nil)))
      (should (member '(function my/org-sync-open) form))
      (should (member '(function my/org-calendar-week) form)))))

(ert-deftest my/sync-ui-legacy-series-approval-still-has-a-working-review-button ()
  (my/calendar-test-workspace
    (let ((marker (my/calendar-test-heading "Legacy series")))
      (org-with-point-at marker
        (org-entry-put nil "GCAL_AUTO_RECURRING" "t")
        ;; A previously saved property, not a shortcut we should suggest now.
        (org-entry-put nil "GCAL_AUTO_ERROR" "Series changes need approval in SPC n g s")
        (my/org-calendar-auto--save))
      (unwind-protect
          (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
            (my/org-calendar-auto-review)
            (with-current-buffer "*Personal Calendar Sync*"
              (should (string-match-p "Approve entire series" (buffer-string)))
              (should (string-match-p "Integrations (SPC n i)" (buffer-string)))
              (should-not (string-match-p "SPC n g s" (buffer-string)))))
        (when (get-buffer "*Personal Calendar Sync*") (kill-buffer "*Personal Calendar Sync*"))))))

(ert-deftest my/sync-ui-native-tooltip-does-not-require-global-tooltip-mode ()
  (my/sync-ui-test-state
    (let ((tooltip-mode nil) (my/org-sync-ui--tooltip-active t)
          (tooltip-help-message (my/org-sync-ui--tooltip 'calendar)) shown)
      (cl-letf (((symbol-function 'tooltip-show)
                 (lambda (text &optional echo-area &rest _)
                   (setq shown (list text echo-area)))))
        (should (my/org-sync-ui--tooltip-tip nil))
        (should (string-match-p "Personal Calendar" (car shown)))
        (should-not (cadr shown))
        (should-not tooltip-mode)
        (setq shown nil tooltip-help-message "Unrelated tooltip")
        (should-not (my/org-sync-ui--tooltip-tip nil))
        (should-not shown)))))

(ert-deftest my/sync-ui-sync-cannot-bypass-pause ()
  (my/sync-ui-test-state
    (let (calls)
      (cl-letf (((symbol-function 'my/org-calendar-auto--schedule) (lambda () (push 'calendar calls)))
                ((symbol-function 'my/org-calendar-fetch) (lambda (&rest _) (ert-fail "Never call legacy fetch"))))
        (my/org-sync-ui--act 'sync 'calendar)
        (should (equal calls '(calendar)))
        (setq my/org-calendar-auto-mode nil)
        (should-error (my/org-sync-ui--act 'sync 'calendar) :type 'user-error)
        (should (equal calls '(calendar)))))))

(ert-deftest my/sync-ui-pause-resume-passes-an-explicit-mode-argument ()
  (my/sync-ui-test-state
    (let (calls)
      (cl-letf (((symbol-function 'my/org-calendar-auto-mode) (lambda (arg) (push arg calls))))
        (my/org-sync-ui--act 'pause 'calendar)
        (setq my/org-calendar-auto-mode nil)
        (my/org-sync-ui--act 'pause 'calendar)
        (should (equal calls '(1 -1)))))))

(ert-deftest my/sync-ui-authorize-starts-only-calendar-sign-in ()
  (my/sync-ui-test-state
    (let (calls)
      (cl-letf (((symbol-function 'my/org-calendar-login) (lambda () (push 'calendar calls))))
        (my/org-sync-ui--act 'authorize 'calendar)
        (should (equal calls '(calendar)))))))

(ert-deftest my/sync-ui-paused-panel-has-resume-but-no-sync-button ()
  (my/sync-ui-test-state
    (setq my/org-calendar-auto-mode nil)
    (my/org-sync-ui-mode)
    (my/org-sync-ui-refresh)
    (let (actions (position (point-min)))
      (while (setq position (next-button position))
        (when (eq (button-get position 'my/org-sync-kind) 'calendar)
          (push (button-get position 'my/org-sync-action) actions))
        (setq position (button-end position)))
      (should (memq 'pause actions))
      (should-not (memq 'sync actions)))
    (should (string-match-p "\\[Resume\\]" (buffer-string)))))

(ert-deftest my/sync-ui-panel-keymap-is-shallow-and-refresh-is-display-only ()
  (should (eq (lookup-key my/org-sync-ui-mode-map (kbd "s")) #'my/org-sync-ui-sync))
  (should (eq (lookup-key my/org-sync-ui-mode-map (kbd "a")) #'my/org-sync-ui-authorize))
  (should (eq (lookup-key my/org-sync-ui-mode-map (kbd "p")) #'my/org-sync-ui-pause))
  (should (eq (lookup-key my/org-sync-ui-mode-map (kbd "g")) #'my/org-sync-ui-refresh))
  (should (eq (lookup-key my/org-sync-ui-mode-map (kbd "q")) #'quit-window)))

(ert-deftest my/sync-ui-clicking-an-action-selects-calendar ()
  (my/sync-ui-test-state
    (my/org-sync-ui-mode)
    (my/org-sync-ui-refresh)
    (let ((position (point-min)) target)
      (while (setq position (next-button position))
        (when (and (eq (button-get position 'my/org-sync-kind) 'calendar)
                   (eq (button-get position 'my/org-sync-action) 'sync))
          (setq target position))
        (setq position (button-end position)))
      (should target)
      (cl-letf (((symbol-function 'my/org-calendar-auto--schedule) #'ignore))
        (button-activate target))
      (should (eq my/org-sync-ui--selected 'calendar)))))

(ert-deftest my/sync-ui-menu-is-display-only-and-disables-paused-sync ()
  (my/sync-ui-test-state
    (setq my/org-calendar-auto-mode nil)
    (let (shown)
      (cl-letf (((symbol-function 'popup-menu) (lambda (map &optional _) (setq shown map)))
                ((symbol-function 'my/org-calendar-auto--schedule) (lambda () (ert-fail "Menu must not sync")))
                ((symbol-function 'my/org-calendar-login) (lambda (&rest _) (ert-fail "Menu must not sign in"))))
        (my/org-sync-ui-menu 'calendar))
      (should (keymapp shown))
      (should-not (plist-get (nthcdr 3 (cdr (assq 'sync (cdr shown)))) :enable))
      (should (assq 'pause (cdr shown)))
      (should-not (assq 'more (cdr shown))))))

(ert-deftest my/sync-ui-live-refresh-keeps-selection-and-never-opens-a-window ()
  (my/sync-ui-test-state
    (let ((buffer (get-buffer-create my/org-sync-ui--buffer)))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (my/org-sync-ui-mode) (my/org-sync-ui--select 'calendar))
            (setq my/org-calendar-auto-status "needs attention" my/org-calendar-auto--last-error "Needs review")
            (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) (selected-window)))
                      ((symbol-function 'pop-to-buffer) (lambda (&rest _) (ert-fail "Refresh must not take focus"))))
              (my/org-sync-ui--changed))
            (with-current-buffer buffer
              (should (eq my/org-sync-ui--selected 'calendar))
              (should (string-match-p "Needs review" (buffer-string)))))
        (kill-buffer buffer)))))

(ert-deftest my/sync-ui-display-errors-cannot-break-a-sync-status-notification ()
  (let ((buffer (get-buffer-create my/org-sync-ui--buffer)))
    (unwind-protect
        (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) (selected-window)))
                  ((symbol-function 'my/org-sync-ui-refresh) (lambda () (error "Broken display"))))
          (my/org-sync-ui--changed))
      (kill-buffer buffer))))

(ert-deftest my/sync-ui-installer-replaces-the-icon-once-and-preserves-other-items ()
  (let ((global-mode-string '("Other" (:eval (my/org-calendar-status-render))))
        (show-help-function nil) (my/org-sync-ui--previous-help-function nil)
        (after-load-functions nil) (tooltip-functions nil)
        (pre-command-hook nil) (x-pre-popup-menu-hook nil)
        (functions '(my/org-calendar-auto--status
                     my/org-calendar-login-sentinel
                     my/org-calendar-keychain-disable)))
    (unwind-protect
        (progn
          (my/org-sync-ui-install) (my/org-sync-ui-install)
          (my/org-calendar-status-install)
          (should (equal global-mode-string (list "Other" my/org-sync-ui--modeline)))
          (should (eq show-help-function #'my/org-sync-ui--show-help))
          (should-not my/org-sync-ui--previous-help-function)
          (should (= 1 (cl-count #'my/org-sync-ui--after-load after-load-functions)))
          (should (advice-member-p #'my/org-sync-ui--changed 'my/org-calendar-auto--status)))
      (dolist (function functions) (advice-remove function #'my/org-sync-ui--changed))
      (advice-remove 'my/org-calendar-keychain--process #'my/org-sync-ui--keychain-process)
      (advice-remove 'my/org-calendar-status-install #'my/org-sync-ui-install))))

(ert-deftest my/sync-ui-calendar-startup-errors-retain-a-safe-reason ()
  (my/calendar-test-workspace
    (let ((my/org-calendar-auto--last-error nil))
      (cl-letf (((symbol-function 'my/org-calendar-auto--list)
                 (lambda (&rest _) (error "private-response-token"))))
        (my/org-calendar-auto--start))
      (should (equal my/org-calendar-auto-status "needs attention"))
      (should (string-match-p "startup failed (error)" my/org-calendar-auto--last-error))
      (should-not (string-match-p "private-response-token" my/org-calendar-auto--last-error)))))

(ert-deftest my/sync-ui-calendar-callback-errors-retain-a-safe-reason ()
  (my/calendar-test-workspace
    (let (callback (my/org-calendar-auto--last-error nil))
      (cl-letf (((symbol-function 'request)
                 (lambda (_url &rest args) (setq callback (plist-get args :complete)) nil))
                ((symbol-function 'request-response-status-code) (lambda (_) 200)))
        (funcall my/sync-ui-test-calendar-request "GET" nil nil nil
                 (lambda (&rest _) (error "private-response-token")))
        (funcall callback :response (make-request-response :status-code 200) :data nil))
      (should (equal my/org-calendar-auto-status "needs attention"))
      (should (string-match-p "response failed (error)" my/org-calendar-auto--last-error))
      (should-not (string-match-p "private-response-token" my/org-calendar-auto--last-error)))))

(ert-deftest my/sync-ui-timestamps-only-record-success-after-a-successful-cycle ()
  (my/calendar-test-workspace
    (let ((my/org-calendar-auto--last-success nil))
      (my/org-calendar-auto--finish "up to date")
      (should (numberp my/org-calendar-auto--last-success))
      (let ((success my/org-calendar-auto--last-success))
        (my/org-calendar-auto--finish "needs attention")
        (should (equal success my/org-calendar-auto--last-success))))))

(provide 'org-sync-ui-test)
