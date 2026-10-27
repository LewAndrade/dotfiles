;;; org-sync-ui.el --- One control surface for Personal sync -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)
(require 'button)
(require 'tooltip)

(defvar my/org-calendar-auto-mode)
(defvar my/org-calendar-auto-status)
(defvar my/org-calendar-auto--file)
(defvar my/org-calendar-auto--busy)
(defvar my/org-calendar-auto--last-error)
(defvar my/org-calendar-auto--last-run)
(defvar my/org-calendar-auto--last-success)
(defvar my/org-calendar-auth-problem)
(defvar my/org-calendar-login-process)
(defvar my/org-calendar-keychain-enabled)
(defvar my/org-calendar-repeat--pending)

(declare-function org-map-entries "org" (func &optional match scope &rest skip))
(declare-function org-entry-get "org" (pom property &optional inherit literal-nil))
(declare-function my/org-calendar-auto--schedule "org-calendar-auto" (&rest args))
(declare-function my/org-calendar-auto-mode "org-calendar-auto" (&optional arg))
(declare-function my/org-calendar-auto-review "org-calendar-auto" ())
(declare-function my/org-calendar-login "config" ())
(declare-function my/org-calendar-stop-login "config" (&optional process))
(declare-function my/org-calendar-keychain-enable "org-calendar-keychain" ())
(declare-function my/org-calendar-keychain-disable "org-calendar-keychain" ())
(declare-function my/org-calendar-status-context-p "org-calendar-status" ())
(declare-function evil-set-initial-state "evil-core" (mode state))

(defconst my/org-sync-ui--buffer "*Personal Sync*")
(defconst my/org-sync-ui--modeline '(:eval (my/org-sync-ui-render)))
(defvar my/org-sync-ui--previous-help-function nil)
(defvar my/org-sync-ui--tooltip-active nil)
(defvar-local my/org-sync-ui--selected 'calendar)
(defvar-local my/org-sync-ui--sections nil)

(defun my/org-sync-ui--source-modified-p (file)
  "Inspect an already open FILE without opening or saving it."
  (when-let* ((buffer (and file (get-file-buffer file))))
    (buffer-modified-p buffer)))

(defun my/org-sync-ui--authorizing-p ()
  (when-let* ((process (bound-and-true-p my/org-calendar-login-process)))
    (and (process-live-p process)
         (string-prefix-p "org-calendar-" (process-name process)))))

(defun my/org-sync-ui--snapshot (kind)
  "Read KIND's status without starting sync, loading settings, or opening files."
  (let* ((name "Calendar")
         (configured (bound-and-true-p my/org-calendar-auto--file))
         (enabled (bound-and-true-p my/org-calendar-auto-mode))
         (status (bound-and-true-p my/org-calendar-auto-status))
         (error-text (bound-and-true-p my/org-calendar-auto--last-error))
         (busy (bound-and-true-p my/org-calendar-auto--busy))
         (file (bound-and-true-p my/org-calendar-auto--file))
         (authorizing (my/org-sync-ui--authorizing-p))
         (auth-problem (bound-and-true-p my/org-calendar-auth-problem))
         (state (cond (authorizing 'authorizing)
                      ((and (not configured) error-text) 'error)
                      ((and (not configured)
                            (not (featurep 'org-calendar-auto))) 'unloaded)
                      ((not configured) 'unconfigured)
                      ((not enabled) 'paused)
                      (busy 'syncing)
                      ((equal status "needs login") 'login)
                      ((equal status "needs attention") 'error)
                      ((and (equal status "pending")
                            (or error-text (memq auth-problem '(temporary keychain)))) 'retrying)
                      ((and (equal status "pending") (my/org-sync-ui--source-modified-p file)) 'unsaved)
                      ((equal status "pending") 'waiting)
                      ((equal status "up to date") 'healthy)
                      (t 'waiting)))
         (spec (assq state '((healthy "Up to date" "✓" success)
                             (syncing "Syncing" "↻" shadow)
                             (authorizing "Signing in" "↻" shadow)
                             (waiting "Waiting to sync" "…" shadow)
                             (unsaved "Waiting for save" "…" warning)
                             (retrying "Retrying" "↻" warning)
                             (login "Sign-in needed" "!" warning)
                             (error "Needs attention" "!" error)
                             (paused "Paused" "Ⅱ" shadow)
                             (unloaded "Not started" "?" shadow)
                             (unconfigured "Not configured" "?" shadow)))))
    (list :kind kind :name name :short "Cal"
          :configured configured :enabled enabled :state state
          :label (nth 1 spec) :symbol (nth 2 spec) :face (nth 3 spec)
          :authorizing authorizing :error error-text
          :reason (pcase state
                    ('paused "Automatic sync is paused. Resume it before requesting a sync.")
                    ('unconfigured "Private account approval is not configured.")
                    ('unloaded "Open your Org agenda to initialize this integration. This panel does not start it.")
                    ('authorizing "Complete the Google sign-in window. No other sign-in can start meanwhile.")
                    ('syncing "Saved changes are being checked against Google.")
                    ('unsaved (format "Save %s to continue. Unsaved edits are never sent or replaced."
                                      (file-name-nondirectory file)))
                    ('healthy "Saved changes are up to date.")
                    ('waiting "A guarded sync is queued, or waiting for authorization or another cycle.")
                    ('retrying (or error-text
                                   (if (eq auth-problem 'keychain)
                                       "Keychain unlock is unavailable. Check Keychain setup in the action menu."
                                     "The last connection or sign-in refresh failed. Another attempt will run automatically.")))
                    (_ (or error-text
                           (pcase auth-problem
                             ('unlock "Unlock the encrypted Google token store by signing in again.")
                             ('keychain "Keychain unlock is unavailable. Check Keychain setup in the action menu.")
                             (_ (if (eq state 'login) "Sign in to the approved personal Google account."
                                  "Review conflicts or event validation errors in Details."))))))
          :attempt (bound-and-true-p my/org-calendar-auto--last-run)
          :success (bound-and-true-p my/org-calendar-auto--last-success))))

(defun my/org-sync-ui--time (time)
  (if (and (numberp time) (> time 0))
      (format-time-string "%d %b %H:%M:%S" (seconds-to-time time))
    "Not recorded this session"))

(defun my/org-sync-ui--tooltip (kind)
  (let ((info (my/org-sync-ui--snapshot kind)))
    (propertize
     (format "Personal %s: %s\n%s\nLast successful sync: %s\n%s\nClick: details and controls. Right-click: quick actions."
             (plist-get info :name) (plist-get info :label) (plist-get info :reason)
             (my/org-sync-ui--time (plist-get info :success))
             (if (eq (plist-get info :state) 'retrying)
                 "Another attempt will run automatically."
               "SPC n i opens Integrations."))
     'my/org-sync-tooltip t)))

(defun my/org-sync-ui--show-help (help)
  "Show native hover tips only for our badges, preserving other help behavior."
  (cond
   ((and (stringp help) (> (length help) 0)
         (get-text-property 0 'my/org-sync-tooltip help))
    (setq my/org-sync-ui--tooltip-active t)
    (tooltip-show-help help))
   (t
    (when my/org-sync-ui--tooltip-active
      (tooltip-show-help nil)
      (setq my/org-sync-ui--tooltip-active nil))
    (when (and my/org-sync-ui--previous-help-function
               (not (eq my/org-sync-ui--previous-help-function #'my/org-sync-ui--show-help)))
      (funcall my/org-sync-ui--previous-help-function help)))))

(defun my/org-sync-ui--tooltip-tip (_event)
  "Display only our delayed native tips, even though global Tooltip mode is off."
  (when (and my/org-sync-ui--tooltip-active (stringp tooltip-help-message)
             (> (length tooltip-help-message) 0)
             (get-text-property 0 'my/org-sync-tooltip tooltip-help-message))
    ;; `tooltip-help-tips' would force the echo area when Tooltip mode is off.
    ;; Copy the string because `tooltip-show' can change its face properties.
    (tooltip-show (copy-sequence tooltip-help-message) nil)
    t))

(defun my/org-sync-ui--hide-tooltip ()
  (when my/org-sync-ui--tooltip-active
    (tooltip-show-help nil)
    (setq my/org-sync-ui--tooltip-active nil)))

(defun my/org-sync-ui--select-origin (event)
  (when event
    (let ((window (posn-window (event-start event))))
      (when (window-live-p window) (select-window window)))))

(defun my/org-sync-ui--badge (kind)
  (let* ((info (my/org-sync-ui--snapshot kind))
         (map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1]
                (lambda (event) (interactive "e")
                  (my/org-sync-ui--select-origin event) (my/org-sync-open kind)))
    (define-key map [mode-line mouse-3]
                (lambda (event) (interactive "e") (my/org-sync-ui-menu kind event)))
    (propertize
     (concat " [" (plist-get info :short) " "
             (propertize (plist-get info :symbol) 'face (plist-get info :face)) "] ")
     'local-map map 'mouse-face 'mode-line-highlight
     'help-echo (lambda (_window _object _position) (my/org-sync-ui--tooltip kind)))))

(defun my/org-sync-ui-render ()
  "Render the named, clickable Calendar badge in the modeline."
  (let* ((calendar (my/org-sync-ui--snapshot 'calendar))
         (problem (memq (plist-get calendar :state) '(login error retrying))))
    (when (or problem
              (derived-mode-p 'org-agenda-mode 'org-timegrid-mode)
              (member (buffer-name) (list my/org-sync-ui--buffer "*Personal Calendar Sync*"
                                         "*Personal Calendar Authorization*"))
              (and (fboundp 'my/org-calendar-status-context-p)
                   (my/org-calendar-status-context-p)))
      (when (or problem (plist-get calendar :configured))
        (my/org-sync-ui--badge 'calendar)))))

(defun my/org-sync-ui--issue-count (kind)
  "Count existing review items only when building the panel, not on redisplay."
  (let ((count (cl-count-if (lambda (job) (plist-get job :conflict))
                            (bound-and-true-p my/org-calendar-repeat--pending)))
        (buffer (and (bound-and-true-p my/org-calendar-auto--file)
                     (get-file-buffer my/org-calendar-auto--file))))
    (when buffer
      (with-current-buffer buffer
        (save-excursion
          (save-restriction
            (widen)
            (org-map-entries
             (lambda ()
               (when (or (org-entry-get nil "GCAL_AUTO_ERROR")
                         (org-entry-get nil "GCAL_AUTO_CONFLICT"))
                 (cl-incf count))) nil 'file)))))
    count))

(defun my/org-sync-ui--act (action kind)
  "Perform one explicit ACTION for KIND using the existing guarded commands."
  (let ((info (my/org-sync-ui--snapshot kind)))
    (pcase action
      ('sync
       (unless (and (plist-get info :configured) (plist-get info :enabled))
         (user-error "Configure and resume %s sync first" (plist-get info :name)))
       ;; Never call the legacy fetch command, which has a paused-mode bypass.
       (my/org-calendar-auto--schedule))
      ('authorize
       (when (and (bound-and-true-p my/org-calendar-login-process)
                  (process-live-p my/org-calendar-login-process))
         (user-error "Google sign-in is already running; finish or cancel it first"))
       (my/org-calendar-login))
      ('pause
       (unless (plist-get info :configured) (user-error "Configure this integration first"))
       (my/org-calendar-auto-mode (if (plist-get info :enabled) -1 1)))
      ('details
       (unless (plist-get info :configured) (user-error "Private account approval is not configured yet"))
       (my/org-calendar-auto-review))
      ('cancel
       (unless (plist-get info :authorizing) (user-error "This integration has no sign-in to cancel"))
       (my/org-calendar-stop-login))
      ('keychain (my/org-calendar-keychain-enable))
      ('keychain-forget (my/org-calendar-keychain-disable)))
    (my/org-sync-ui--changed)))

(defun my/org-sync-ui-sync ()
  "Sync the selected integration, never bypassing pause or conflict safeguards."
  (interactive) (my/org-sync-ui--act 'sync my/org-sync-ui--selected))
(defun my/org-sync-ui-authorize ()
  "Authorize the selected integration only."
  (interactive) (my/org-sync-ui--act 'authorize my/org-sync-ui--selected))
(defun my/org-sync-ui-pause ()
  "Pause or resume the selected integration."
  (interactive) (my/org-sync-ui--act 'pause my/org-sync-ui--selected))
(defun my/org-sync-ui-details ()
  "Open the selected integration's existing safe review screen."
  (interactive) (my/org-sync-ui--act 'details my/org-sync-ui--selected))

(defun my/org-sync-ui--button (label action kind)
  (insert-text-button (concat "[" label "]") 'follow-link t
                      'my/org-sync-kind kind 'my/org-sync-action action
                      'action (lambda (_)
                                (setq my/org-sync-ui--selected kind)
                                (my/org-sync-ui--act action kind)))
  (insert "  "))

(defun my/org-sync-ui-refresh ()
  "Refresh the panel from local state without syncing or saving source files."
  (interactive)
  (let ((inhibit-read-only t) (position (point)))
    (erase-buffer)
    (setq my/org-sync-ui--sections nil)
    (insert (propertize "Personal sync\n" 'face 'bold)
            "c Calendar   s Sync   a Authorize   p Pause/resume   d Details\n"
            "g Refresh display   TAB Next button   q Close\n\n")
    (dolist (kind '(calendar))
      (let* ((info (my/org-sync-ui--snapshot kind))
             (issues (my/org-sync-ui--issue-count kind)))
        (push (cons kind (point)) my/org-sync-ui--sections)
        (insert (propertize (concat (if (eq kind my/org-sync-ui--selected) "● " "  ")
                                   (plist-get info :name)) 'face 'bold)
                "   " (propertize (plist-get info :label) 'face (plist-get info :face)) "\n"
                (plist-get info :reason) "\n"
                "Last successful sync: " (my/org-sync-ui--time (plist-get info :success)) "\n"
                "Last attempt: " (my/org-sync-ui--time (plist-get info :attempt)) "\n")
        (when (> issues 0)
          (insert (format "%d item%s need review.\n" issues (if (= issues 1) "" "s"))))
        (when (and (plist-get info :configured) (plist-get info :enabled))
          (my/org-sync-ui--button "Sync now" 'sync kind))
        (unless (eq (plist-get info :state) 'unloaded)
          (if (plist-get info :authorizing)
              (my/org-sync-ui--button "Cancel sign-in" 'cancel kind)
            (my/org-sync-ui--button (concat "Authorize " (plist-get info :name)) 'authorize kind)))
        (when (plist-get info :configured)
          (my/org-sync-ui--button (if (plist-get info :enabled) "Pause" "Resume") 'pause kind)
          (my/org-sync-ui--button (if (> issues 0) "Review issues" "Details") 'details kind))
        (insert "\n\n")))
    (insert (propertize "Keychain unlock" 'face 'bold)
            (if (bound-and-true-p my/org-calendar-keychain-enabled) ": Enabled  " ": Not enabled  "))
    (if (fboundp 'my/org-calendar-keychain-enable)
        (progn
          (my/org-sync-ui--button "Set up / update" 'keychain 'calendar)
          (when (fboundp 'my/org-calendar-keychain-disable)
            (my/org-sync-ui--button "Forget unlock..." 'keychain-forget 'calendar)))
      (insert "Open your Org agenda to initialize Keychain settings."))
    (insert "\nThe unlock is shared; Google authorization stays separate.\n\n")
    (insert (propertize "Personal only. Work stays local.\n" 'face 'shadow)
            "Opening this panel does not sync, save files, or start sign-in.\n")
    (goto-char (min position (point-max)))))

(defun my/org-sync-ui--select (kind)
  (setq my/org-sync-ui--selected kind)
  (my/org-sync-ui-refresh)
  (goto-char (alist-get kind my/org-sync-ui--sections)))

(defvar my/org-sync-ui-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "c") (lambda () (interactive) (my/org-sync-ui--select 'calendar)))
    (define-key map (kbd "s") #'my/org-sync-ui-sync)
    (define-key map (kbd "a") #'my/org-sync-ui-authorize)
    (define-key map (kbd "p") #'my/org-sync-ui-pause)
    (define-key map (kbd "d") #'my/org-sync-ui-details)
    (define-key map (kbd "g") #'my/org-sync-ui-refresh)
    (define-key map (kbd "TAB") #'forward-button)
    (define-key map (kbd "<backtab>") #'backward-button)
    map))

(define-derived-mode my/org-sync-ui-mode special-mode "Personal Sync"
  "Inspect the Personal Calendar integration; actions always require an explicit command."
  (setq-local truncate-lines nil))

(defun my/org-sync-ui-fit-window (window)
  "Fit the integration section, using at most half of WINDOW's frame."
  (let ((maximum (max window-min-height
                      (floor (* 0.5 (frame-height (window-frame window)))))))
    (fit-window-to-buffer window maximum (min 10 maximum))))

;;;###autoload
(defun my/org-sync-open (&optional kind)
  "Open shared Integrations, focusing KIND (Calendar by default)."
  (interactive)
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'my/org-sync-ui-mode 'emacs))
  (let ((buffer (get-buffer-create my/org-sync-ui--buffer)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'my/org-sync-ui-mode) (my/org-sync-ui-mode))
      (my/org-sync-ui--select (or kind my/org-sync-ui--selected)))
    (pop-to-buffer buffer '((display-buffer-reuse-window display-buffer-in-side-window)
                           (side . bottom) (slot . 0)
                           (window-height . my/org-sync-ui-fit-window)))))

(defun my/org-sync-ui-menu (kind &optional event)
  "Show KIND's status and direct actions, with no nested More submenu."
  (my/org-sync-ui--select-origin event)
  (let* ((info (my/org-sync-ui--snapshot kind))
         (map (make-sparse-keymap (concat "Personal " (plist-get info :name))))
         (configured (plist-get info :configured)))
    (dolist (item `((keychain "Keychain setup" keychain t)
                    (details "Details / review issues" details ,configured)
                    (pause ,(if (plist-get info :enabled) "Pause" "Resume") pause ,configured)
                    (authorize "Authorize" authorize
                               ,(not (and (bound-and-true-p my/org-calendar-login-process)
                                          (process-live-p my/org-calendar-login-process))))
                    (sync "Sync now" sync ,(and configured (plist-get info :enabled)))))
      (let ((action (nth 2 item)))
        (define-key map (vector (car item))
                    `(menu-item ,(nth 1 item)
                                ,(lambda () (interactive) (my/org-sync-ui--act action kind))
                                :enable ,(and (nth 3 item) t)))))
    (when (plist-get info :authorizing)
      (define-key map [cancel] `(menu-item "Cancel sign-in"
                                         ,(lambda () (interactive) (my/org-sync-ui--act 'cancel kind)))))
    (define-key map [panel] `(menu-item "Open Integrations"
                                      ,(lambda () (interactive) (my/org-sync-open kind))))
    (define-key map [state] `(menu-item ,(plist-get info :label) ignore :enable nil))
    (popup-menu map event)))

(defun my/org-sync-ui--changed (&rest _)
  "Update an existing visible panel without opening it or taking focus."
  (force-mode-line-update t)
  (when-let* ((buffer (get-buffer my/org-sync-ui--buffer)))
    (when (get-buffer-window buffer t)
      ;; A display problem must never interrupt the sync engine that notified us.
      (condition-case problem
          (with-current-buffer buffer (my/org-sync-ui-refresh))
        (error (message "Integrations panel refresh failed (%s)" (car problem)))))))

(defun my/org-sync-ui--keychain-process (original operation passphrase callback)
  "Refresh Keychain status after an explicit asynchronous operation finishes."
  (funcall original operation passphrase
           (lambda (success)
             (unwind-protect (funcall callback success)
               (my/org-sync-ui--changed)))))

(defun my/org-sync-ui--after-load (file)
  (when (string-match-p "/org-\\(?:calendar-\\(?:auto\\|status\\|keychain\\)\\)\\.elc?\\'" file)
    (my/org-sync-ui-install)))

(defun my/org-sync-ui-install ()
  "Replace the anonymous icons and install selective native hover help."
  (setq global-mode-string
        (cl-remove-if
         (lambda (entry)
           (member entry (list '(:eval (my/org-calendar-status-render))
                               'my/org-calendar-status-mode-line my/org-sync-ui--modeline)))
         global-mode-string))
  (add-to-list 'global-mode-string my/org-sync-ui--modeline t)
  (unless (eq show-help-function #'my/org-sync-ui--show-help)
    (setq my/org-sync-ui--previous-help-function show-help-function
          show-help-function #'my/org-sync-ui--show-help))
  (dolist (function '(my/org-calendar-auto--status
                      my/org-calendar-login-sentinel
                      my/org-calendar-keychain-disable))
    (when (fboundp function)
      (advice-add function :after #'my/org-sync-ui--changed)))
  (when (fboundp 'my/org-calendar-keychain--process)
    (advice-add 'my/org-calendar-keychain--process :around #'my/org-sync-ui--keychain-process))
  ;; Resuming Calendar reinstalls its legacy status entry without reloading a file.
  (when (fboundp 'my/org-calendar-status-install)
    (advice-add 'my/org-calendar-status-install :after #'my/org-sync-ui-install))
  (add-hook 'after-load-functions #'my/org-sync-ui--after-load)
  (add-hook 'tooltip-functions #'my/org-sync-ui--tooltip-tip)
  (add-hook 'pre-command-hook #'my/org-sync-ui--hide-tooltip)
  (add-hook 'x-pre-popup-menu-hook #'my/org-sync-ui--hide-tooltip)
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'my/org-sync-ui-mode 'emacs))
  (my/org-sync-ui--changed))

(provide 'org-sync-ui)
;;; org-sync-ui.el ends here
