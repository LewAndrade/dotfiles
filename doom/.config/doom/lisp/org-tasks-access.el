;;; org-tasks-access.el --- Separate Personal Tasks grant and read-only setup -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'json)
(require 'request)
(require 'subr-x)
(defvar my/org-calendar-login-process)
(defvar my/org-calendar-auth-worker-file)
(defvar my/org-calendar-settings-file)
(defvar my/org-calendar-approved-primary-id)
(defvar my/org-calendar-token-passphrase)
(defvar my/org-calendar-auth-problem)
(defvar my/org-calendar-keychain-helper-file)
(defvar oauth2-auto-plstore)
(declare-function my/org-calendar-prepare "config" ())
(declare-function my/org-calendar-unlock-available-p "config" ())
(declare-function my/org-calendar-stop-login "config" (&optional process))
(declare-function my/org-calendar-open-auth-url "config" (url &rest args))
(declare-function my/org-calendar-configured-id-p "org-calendar-config" (id))

(defvar my/org-tasks-access-token nil)
(defvar my/org-tasks-token-expiration nil)
(defvar my/org-tasks-token-account nil)
(defvar my/org-tasks-access-status "not authorized")
(defvar my/org-tasks-access-error nil)
(defvar my/org-tasks-access-error-reasons nil)
(defvar my/org-tasks-access-lists nil)
(defvar my/org-tasks-access-counts nil)
(defvar my/org-tasks-access-request nil)
(defvar my/org-tasks-access-generation 0)
(defvar my/org-tasks-auth-problem nil)
(defvar my/org-tasks-auth-retry-after 0)
(defvar my/org-tasks-auth-finished-hook nil
  "Functions called with SUCCESS and BACKGROUND after Tasks authorization.")
(declare-function my/org-tasks-mode "org-tasks-sync" (&optional arg))

(defun my/org-tasks-session-ready-p ()
  "Return non-nil for a Tasks token with at least sixty seconds remaining."
  (and (stringp my/org-tasks-access-token)
       (equal my/org-tasks-token-account my/org-calendar-approved-primary-id)
       (not (string-empty-p my/org-tasks-access-token))
       (numberp my/org-tasks-token-expiration)
       (> my/org-tasks-token-expiration (+ (float-time) 60))))

(defun my/org-tasks-access-show ()
  "Show safe setup results, never token contents or task titles."
  (interactive)
  (with-current-buffer (get-buffer-create "*Personal Tasks Setup*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert "Personal Google Tasks setup\n\nStatus: " my/org-tasks-access-status "\n")
      (when my/org-tasks-access-error (insert my/org-tasks-access-error "\n"))
      (insert "\nCalendar has a separate token. This setup page only inspects lists.\n"
              (if (bound-and-true-p my/org-tasks-mode)
                  "Automatic task sync is enabled separately; SPC n T s shows its status.\n\n"
                "No automatic task sync is enabled.\n\n"))
      (dolist (list my/org-tasks-access-lists)
        (insert (format "%s: %s active, %s completed\n"
                        (or (plist-get list :title) "Untitled list")
                        (or (car (alist-get (plist-get list :id) my/org-tasks-access-counts nil nil #'equal)) "?")
                        (or (cdr (alist-get (plist-get list :id) my/org-tasks-access-counts nil nil #'equal)) "?"))))
      (insert "\nRepeat setup: SPC n g m t. Cancel login: SPC n g m c.\n"))
    (special-mode))
  (display-buffer "*Personal Tasks Setup*"))

(defun my/org-tasks-access-fail (status data)
  "Report safe HTTP STATUS without exposing DATA or altering Calendar auth."
  (setq my/org-tasks-access-error-reasons
        (delq nil (mapcar (lambda (item) (plist-get item :reason))
                         (append (plist-get (plist-get data :error) :errors)
                                 (plist-get (plist-get data :error) :details)))))
  (setq my/org-tasks-access-status "needs attention"
        my/org-tasks-access-error
        (cond
         ((eq status 401) "Tasks authorization expired or was rejected; run setup again.")
         ((and (eq status 403)
               (or (member "accessNotConfigured" my/org-tasks-access-error-reasons)
                   (member "SERVICE_DISABLED" my/org-tasks-access-error-reasons)))
          "Enable Google Tasks API in the same Google Cloud project as Calendar, then repeat setup.")
         ((and (eq status 403) (member "ACCESS_TOKEN_SCOPE_INSUFFICIENT" my/org-tasks-access-error-reasons))
          "Tasks permission was not granted. Repeat setup (SPC n g m t) and allow Google Tasks access.")
         ((eq status 403) "Tasks permission is missing or access is denied; check consent and Google Tasks API activation.")
         (t "Tasks could not be reached. Calendar sync is unchanged; repeat setup later.")))
  (when (eq status 401) (setq my/org-tasks-access-token nil my/org-tasks-token-expiration nil))
  (my/org-tasks-access-show))

(defun my/org-tasks-access-get (path params callback)
  "Read Tasks PATH with PARAMS, delivering status and data to CALLBACK."
  (unless (my/org-tasks-session-ready-p) (user-error "Run Tasks setup first"))
  (let ((generation my/org-tasks-access-generation))
    (setq my/org-tasks-access-request
          (request (concat "https://tasks.googleapis.com/tasks/v1/" path)
                   :type "GET" :timeout 20 :params params
                   :headers `(("Authorization" . ,(concat "Bearer " my/org-tasks-access-token)))
                   :parser (lambda () (json-parse-buffer :object-type 'plist :array-type 'list
                                                       :null-object nil :false-object nil))
                   :complete (cl-function
                              (lambda (&key response data &allow-other-keys)
                                (when (= generation my/org-tasks-access-generation)
                                  (funcall callback (request-response-status-code response) data))))))))

(defun my/org-tasks-access-count (lists &optional page active completed)
  "Read every page of LISTS to count tasks without importing their contents."
  (if (null lists)
      (progn (setq my/org-tasks-access-status "authorized; list inspection complete"
                   my/org-tasks-access-error nil my/org-tasks-access-error-reasons nil)
             (my/org-tasks-access-show))
    (let ((id (plist-get (car lists) :id)))
      (my/org-tasks-access-get
       (concat "lists/" (url-hexify-string id) "/tasks")
       (append '((maxResults . "100") (showCompleted . "true") (showHidden . "true")
                 (showDeleted . "true") (showAssigned . "false"))
               (when page (list (cons 'pageToken page))))
       (lambda (status data)
         (if (not (eq status 200)) (my/org-tasks-access-fail status data)
           (let ((open (or active 0)) (done (or completed 0)))
             (dolist (task (plist-get data :items))
               (unless (plist-get task :deleted)
                 (if (equal (plist-get task :status) "completed") (cl-incf done) (cl-incf open))))
             (if-let* ((next (plist-get data :nextPageToken)))
                 (my/org-tasks-access-count lists next open done)
               (setf (alist-get id my/org-tasks-access-counts nil nil #'equal) (cons open done))
               (my/org-tasks-access-count (cdr lists))))))))))

(defun my/org-tasks-access-list (&optional page collected)
  "Read all existing task lists; never create or choose a new list implicitly."
  (my/org-tasks-access-get
   "users/@me/lists" (append '((maxResults . "100")) (when page (list (cons 'pageToken page))))
   (lambda (status data)
     (if (not (eq status 200)) (my/org-tasks-access-fail status data)
       (let ((lists (append collected (plist-get data :items))))
         (if-let* ((next (plist-get data :nextPageToken)))
             (my/org-tasks-access-list next lists)
           (setq my/org-tasks-access-lists lists my/org-tasks-access-counts nil)
           (my/org-tasks-access-count lists)))))))

(defun my/org-tasks-login-filter (process output)
  "Receive private worker OUTPUT without modifying Calendar's in-memory token."
  (let ((pending (concat (or (process-get process 'pending) "") output)))
    (while (string-match "\n" pending)
      (let ((line (substring pending 0 (match-beginning 0))))
        (setq pending (substring pending (match-end 0)))
        (cond
         ((string-prefix-p "ORG-CALENDAR URL " line)
          (if (process-get process 'background) (my/org-calendar-stop-login process)
            (my/org-calendar-open-auth-url (json-parse-string (substring line 17)))))
         ((string-prefix-p "ORG-CALENDAR TOKEN " line)
           (let ((data (json-parse-string (substring line 19) :object-type 'plist)))
             (if (not (equal (process-get process 'tasks-account) my/org-calendar-approved-primary-id))
                 (process-put process 'failure-kind "authorization")
               (setq my/org-tasks-access-token (plist-get data :token)
                     my/org-tasks-token-account (process-get process 'tasks-account)
                     my/org-tasks-token-expiration (plist-get data :expiration))
               (process-put process 'authenticated (my/org-tasks-session-ready-p)))))
         ((string-prefix-p "ORG-CALENDAR ERROR " line)
          (process-put process 'failure-kind (substring line 19))))))
    (process-put process 'pending pending)))

(defun my/org-tasks-login-sentinel (process _event)
  "Finish Tasks PROCESS without clearing or restarting Calendar's session."
  (when (and (memq (process-status process) '(exit signal closed failed))
             (eq process my/org-calendar-login-process))
    (when-let* ((timer (process-get process 'timeout-timer))) (cancel-timer timer))
    (setq my/org-calendar-login-process nil)
    (let* ((background (process-get process 'background))
           (success (and (zerop (process-exit-status process))
                         (process-get process 'authenticated) (not (process-get process 'stopped)))))
       (setq my/org-tasks-auth-problem
             (unless success
               (if (and (process-get process 'stopped) (not background)) 'authorization
                 (intern (or (process-get process 'failure-kind) "temporary"))))
            my/org-tasks-auth-retry-after
            (if (memq my/org-tasks-auth-problem '(temporary keychain)) (+ (float-time) 60) 0))
      (if success
          (progn
            (setq my/org-tasks-access-status "authorized" my/org-tasks-access-error nil)
            (unless background (my/org-tasks-access-list)))
        (setq my/org-tasks-access-token nil my/org-tasks-token-expiration nil
              my/org-tasks-access-status "not authorized"
              my/org-tasks-access-error
              (pcase my/org-tasks-auth-problem
                ('authorization "Tasks consent is required. Use the approved personal account and grant Tasks access.")
                ('unlock "The encrypted token store could not be unlocked; retry setup.")
                ('keychain "Keychain unlock is unavailable; check Calendar Keychain setup.")
                (_ "Tasks login stopped or the connection failed; repeat setup.")))
         (unless background (my/org-tasks-access-show)))
      (when (eq my/org-tasks-auth-problem 'unlock)
        (when my/org-calendar-token-passphrase (clear-string my/org-calendar-token-passphrase))
        (setq my/org-calendar-token-passphrase nil))
      (run-hook-with-args 'my/org-tasks-auth-finished-hook success background))))

(defun my/org-tasks-launch-auth (&optional background force)
  "Launch serialized Tasks authorization; BACKGROUND never prompts or logs in."
  (when (and my/org-calendar-login-process (process-live-p my/org-calendar-login-process))
    (user-error "Google authorization is already running"))
  (when (and background (not (my/org-calendar-unlock-available-p)))
    (user-error "Unlock Google tokens or configure Keychain first"))
  (let ((passphrase
         (cond (my/org-calendar-token-passphrase (copy-sequence my/org-calendar-token-passphrase))
               ((and (my/org-calendar-unlock-available-p)
                    (not (memq 'unlock (list my/org-calendar-auth-problem my/org-tasks-auth-problem)))) nil)
               (background (user-error "Background refresh cannot prompt for an unlock"))
               (t (read-passwd "Unlock existing encrypted Google tokens, not your Google password: ")))))
    (unwind-protect
        (progn
          (when (and passphrase (string-empty-p passphrase)) (user-error "The unlock cannot be empty"))
          (setq my/org-tasks-access-status "authorizing" my/org-tasks-access-error nil
                my/org-tasks-auth-problem nil my/org-tasks-auth-retry-after 0
                my/org-tasks-access-error-reasons nil
                my/org-tasks-access-token nil my/org-tasks-token-expiration nil)
          (unless background (my/org-tasks-access-show))
          (when (and passphrase (not background))
            (setq my/org-calendar-token-passphrase (copy-sequence passphrase)))
          (setq my/org-calendar-login-process
                (make-process
                 :name "org-tasks-login" :buffer nil :noquery t :connection-type 'pipe
                 :command (append (list (expand-file-name invocation-name invocation-directory)
                                        "-Q" "--batch" "--eval" (prin1-to-string `(setq load-path ',load-path))
                                        "-l" my/org-calendar-auth-worker-file
                                        "--" my/org-calendar-settings-file oauth2-auto-plstore
                                        (cond (background "tasks-refresh-only") (force "tasks-reauthorize") (t "tasks-login")))
                                  (when (null passphrase) (list "keychain" my/org-calendar-keychain-helper-file)))
                 :filter #'my/org-tasks-login-filter :sentinel #'my/org-tasks-login-sentinel))
          (process-put my/org-calendar-login-process 'background background)
          (process-put my/org-calendar-login-process 'tasks-account
                       (copy-sequence my/org-calendar-approved-primary-id))
          (when passphrase (process-send-string my/org-calendar-login-process (concat passphrase "\n")))
          (process-put my/org-calendar-login-process 'timeout-timer
                       (run-at-time (if background 30 180) nil #'my/org-calendar-stop-login my/org-calendar-login-process)))
      (when passphrase (clear-string passphrase)))))

(defun my/org-tasks-background-refresh ()
  "Refresh only the Tasks grant, silently and without overlapping store writes."
  (when (and (my/org-calendar-unlock-available-p)
             (not (memq my/org-tasks-auth-problem '(authorization unlock)))
             (>= (float-time) my/org-tasks-auth-retry-after)
             (not (and my/org-calendar-login-process (process-live-p my/org-calendar-login-process))))
    (condition-case nil (my/org-tasks-launch-auth t)
      (error (setq my/org-tasks-auth-problem 'temporary
                   my/org-tasks-auth-retry-after (+ (float-time) 60))))))

;;;###autoload
(defun my/org-tasks-setup (&optional force)
  "Authorize Personal Tasks and inspect lists; prefix FORCE requests new consent."
  (interactive "P")
  (my/org-calendar-prepare)
  (unless (and my/org-calendar-approved-primary-id
               (my/org-calendar-configured-id-p my/org-calendar-approved-primary-id))
    (user-error "Approve the exact personal primary account before Tasks setup"))
  (when (and my/org-calendar-login-process (process-live-p my/org-calendar-login-process))
    (user-error "Google authorization is already running; wait or cancel it first"))
  ;; A user-requested retry must not keep reusing a partially granted token.
  ;; This only requests consent when setup is explicitly invoked, never in a timer.
  (setq force (or force (member "ACCESS_TOKEN_SCOPE_INSUFFICIENT" my/org-tasks-access-error-reasons)))
  (cl-incf my/org-tasks-access-generation)
  (if (and (not force) (my/org-tasks-session-ready-p))
      (my/org-tasks-access-list)
    (setq my/org-tasks-access-lists nil my/org-tasks-access-counts nil)
    (my/org-tasks-launch-auth nil force)))

(provide 'org-tasks-access)
