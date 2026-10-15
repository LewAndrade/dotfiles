;;; org-calendar-auth.el -*- lexical-binding: t; -*-
;; Run only in a disposable batch Emacs. No Org event files are modified here.
(require 'subr-x)
(require 'json)

(defvar epg-pinentry-mode)
(defvar oauth2-auto-plstore)
(defvar oauth2-auto-manually-auth)
(defvar oauth2-auto-additional-providers-alist)
(defvar org-gcal-client-id)
(defvar org-gcal-client-secret)
(load (expand-file-name "org-calendar-config.el"
                        (file-name-directory (or load-file-name buffer-file-name))) nil t)
(defvar my/org-calendar-worker-failure-kind "temporary"
  "Safe error category; never send dependency error messages to the editor.")
(defvar my/org-calendar-worker-library-only nil
  "Non-nil only when tests load worker definitions without running its entry point.")

(defun my/org-calendar-worker-keychain-passphrase (helper store)
  "Read only STORE's opted-in Keychain item through the native HELPER."
  (setq my/org-calendar-worker-failure-kind "keychain")
  (with-temp-buffer
    (unless (and helper (file-executable-p helper)
                 (= 0 (call-process helper nil (list (current-buffer) nil) nil "get"
                                    "org.doom-emacs.personal-calendar" (file-truename store))))
      (error "Keychain unlock unavailable"))
    (when (string-empty-p (buffer-string)) (error "Keychain item is empty"))
    (buffer-string)))
(declare-function aio-wait-for "aio" (promise))
(declare-function oauth2-auto-plist "oauth2-auto" (username provider))
(declare-function oauth2-auto-refresh "oauth2-auto" (username provider plist))
(declare-function oauth2-auto--plstore-read "oauth2-auto" (username provider))
(declare-function oauth2-auto--plstore-write "oauth2-auto" (username provider plist))
(declare-function oauth2-auto-authenticate "oauth2-auto" (username provider))
(declare-function url-retrieve-synchronously "url" (url &optional silent inhibit-cookies timeout))
(defvar url-http-response-status)
(defvar url-request-extra-headers)

(defun my/org-tasks-worker-provider ()
  "Register a separate Tasks grant, never replace Calendar's provider or token."
  (add-to-list 'oauth2-auto-additional-providers-alist
               `(org-tasks
                 (authorize_url . "https://accounts.google.com/o/oauth2/auth")
                 (token_url . "https://oauth2.googleapis.com/token")
                 (scope . "openid email https://www.googleapis.com/auth/tasks")
                 (client_id . ,org-gcal-client-id)
                 (client_secret . ,org-gcal-client-secret))))

(defun my/org-tasks-worker-consent (original provider url-key keys parameters &optional quiet)
  "Obtain an offline Tasks grant without changing Calendar's authorization flow."
  (funcall original provider url-key keys
           (if (eq provider 'org-tasks)
               (append '((prompt . "consent select_account") (include_granted_scopes . "true")) parameters)
             parameters)
           quiet))

(defun my/org-tasks-worker-check-account (account token)
  "Verify TOKEN belongs to approved ACCOUNT before storing or exposing it."
  (require 'url)
  (let* ((url-request-extra-headers
          `(("Authorization" . ,(concat "Bearer " (plist-get token :access-token)))))
         (buffer (url-retrieve-synchronously
                  "https://openidconnect.googleapis.com/v1/userinfo" t t 20)))
    (unless buffer (error "Account verification unavailable"))
    (unwind-protect
        (with-current-buffer buffer
          (unless (and (= (or url-http-response-status 0) 200)
                       (progn (goto-char (point-min)) (re-search-forward "\r?\n\r?\n" nil t)))
            (error "Account verification failed"))
          (let ((info (json-parse-buffer :object-type 'plist)))
            (unless (and (equal (plist-get info :email) account)
                         (eq (plist-get info :email_verified) t))
              (setq my/org-calendar-worker-failure-kind "authorization")
              (error "Tasks account does not match approval"))))
      (kill-buffer buffer))))

(defun my/org-tasks-worker-token (account refresh-only &optional force)
  "Authorize or quietly refresh Tasks for ACCOUNT, preserving Calendar's grant."
  (unless (and (equal account my/org-calendar-approved-primary-id)
               (my/org-calendar-configured-id-p account)
               (not (string-suffix-p "@group.calendar.google.com" account)))
    (setq my/org-calendar-worker-failure-kind "authorization")
    (error "Tasks requires an approved personal account"))
  (my/org-tasks-worker-provider)
  (advice-add 'oauth2-auto--browser-request :around #'my/org-tasks-worker-consent)
  (let* ((stored (oauth2-auto--plstore-read account 'org-tasks))
         (token
          (cond
           (refresh-only
            (unless (plist-get stored :refresh-token)
              (setq my/org-calendar-worker-failure-kind "authorization")
              (error "Explicit Tasks authorization required"))
            (aio-wait-for (oauth2-auto-refresh account 'org-tasks stored)))
           ((and (not force) (plist-get stored :refresh-token)
                 (not (my/org-calendar-worker-needs-refresh-p stored))) stored)
           ;; Explicit Tasks login can authorize again; background refresh cannot.
           (t (aio-wait-for (oauth2-auto-authenticate account 'org-tasks))))))
    (my/org-tasks-worker-check-account account token)
    (oauth2-auto--plstore-write account 'org-tasks token)))

(defun my/org-calendar-worker-read-token (original &rest arguments)
  "Classify store unlock errors separately from transient network failures."
  (setq my/org-calendar-worker-failure-kind "unlock")
  (prog1 (apply original arguments)
    (setq my/org-calendar-worker-failure-kind "temporary")))

(defun my/org-calendar-worker-classify-response (response)
  "Recognize permanent OAuth failures without exposing RESPONSE contents."
  (when (member (cdr (assq 'error response))
                '("invalid_grant" "invalid_client" "unauthorized_client" "access_denied"))
    (setq my/org-calendar-worker-failure-kind "authorization"))
  response)

(defun my/org-calendar-worker-needs-refresh-p (token)
  "Refresh TOKEN before the editor's sixty-second validity margin."
  (let ((expiration (plist-get token :expiration)))
    (or (not (numberp expiration)) (<= expiration (+ (float-time) 120)))))

(defun my/org-calendar-worker-token (calendar refresh-only)
  "Read or renew CALENDAR's token; REFRESH-ONLY never falls back to login."
  (if (not refresh-only)
      (aio-wait-for (oauth2-auto-plist calendar 'org-gcal))
    (let ((stored (oauth2-auto--plstore-read calendar 'org-gcal)))
      (unless (plist-get stored :refresh-token)
        (setq my/org-calendar-worker-failure-kind "authorization")
        (error "Explicit authorization required"))
      ;; Always renew here: the editor may have received 401 even before expiry.
      ;; Do not use refresh-or-authenticate, which treats offline errors as login.
      (oauth2-auto--plstore-write
       calendar 'org-gcal (aio-wait-for (oauth2-auto-refresh calendar 'org-gcal stored))))))

(defun my/org-calendar-worker-send (line)
  "Send LINE immediately; batch `princ' buffers output when using a pipe."
  (let ((coding-system-for-write 'utf-8-unix))
    (write-region (concat line "\n") nil "/dev/stdout" t 'silent)))

(defun my/org-calendar-worker-main ()
  "Read local settings and authorize; emit only the parent's private protocol."
  (let* ((arguments (delete "--" command-line-args-left))
         (settings (car arguments))
         (store (cadr arguments))
          (refresh-only (equal (nth 2 arguments) "refresh-only"))
          (tasks (member (nth 2 arguments) '("tasks-login" "tasks-reauthorize" "tasks-refresh-only")))
          (keychain (equal (nth 3 arguments) "keychain"))
          (helper (nth 4 arguments))
          (passphrase nil))
     (setq command-line-args-left nil)
    (when tasks (setq refresh-only (equal (nth 2 arguments) "tasks-refresh-only")))
    (unwind-protect
        (condition-case nil
             (progn
               (setq passphrase (if keychain
                                    (my/org-calendar-worker-keychain-passphrase helper store)
                                  (read-string "")))
               (setq my/org-calendar-worker-failure-kind "temporary")
              (unless (and settings store (file-readable-p settings)
                           (not (string-empty-p passphrase)))
                (error "Missing settings or passphrase"))
              ;; Isolate package caches from the editor and tracked repositories.
              (setq user-emacs-directory (file-name-directory settings)
                    oauth2-auto-plstore store
                    epg-pinentry-mode 'loopback)
              (load settings nil t)
              (unless (my/org-calendar-configured-id-p my/org-calendar-id)
                (error "Calendar ID requires explicit approval"))
              (require 'org-gcal)
              (advice-add 'oauth2-auto--plstore-read :around #'my/org-calendar-worker-read-token)
              (advice-add 'oauth2-auto--request-access-parse :filter-return
                          #'my/org-calendar-worker-classify-response)
              (advice-add 'oauth2-auto--plist-needs-refreshing :override
                          #'my/org-calendar-worker-needs-refresh-p)
              (when refresh-only
                ;; A revoked/expired refresh token needs explicit user authorization.
                ;; Never open a browser from a periodic sync or show a batch prompt.
                (advice-add 'oauth2-auto--browser-request :override
                            (lambda (&rest _)
                              (setq my/org-calendar-worker-failure-kind "authorization")
                              (error "Interactive login required"))))
              (setq oauth2-auto-manually-auth nil
                    browse-url-browser-function
                    (lambda (url &rest _)
                      (my/org-calendar-worker-send (concat "ORG-CALENDAR URL " (json-encode url)))))
              ;; Encryption stays enabled; no passphrase is written to disk.
              (advice-add 'plstore-passphrase-callback-function :override
                          (lambda (&rest _) (copy-sequence passphrase)))
              (let ((token (if tasks
                               (apply #'my/org-tasks-worker-token my/org-calendar-approved-primary-id refresh-only
                                      (when (equal (nth 2 arguments) "tasks-reauthorize") '(t)))
                             (my/org-calendar-worker-token my/org-calendar-id refresh-only))))
                (unless (and (stringp (plist-get token :access-token))
                             (not (string-empty-p (plist-get token :access-token)))
                             (numberp (plist-get token :expiration))
                             (> (plist-get token :expiration) (+ (float-time) 60)))
                  (error "No usable access token returned"))
                (when (file-exists-p store) (set-file-modes store #o600))
                (my/org-calendar-worker-send (concat "ORG-CALENDAR TOKEN "
                               (json-encode `((token . ,(plist-get token :access-token))
                                              (expiration . ,(plist-get token :expiration))))))))
          (error
           ;; Dependency errors can contain tokens. Never print their payloads.
            (my/org-calendar-worker-send
             (concat "ORG-CALENDAR ERROR " my/org-calendar-worker-failure-kind))
           (kill-emacs 1)))
      (when passphrase (clear-string passphrase)))))

(when (and noninteractive (not my/org-calendar-worker-library-only)) (my/org-calendar-worker-main))
