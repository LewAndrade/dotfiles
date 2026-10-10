;;; org-calendar-keychain.el --- Optional macOS automatic calendar unlock -*- lexical-binding: t; -*-
(require 'subr-x)

(defvar my/org-calendar-settings-file)
(defvar my/org-calendar-auth-worker-file)
(defvar my/org-calendar-token-passphrase)
(defvar my/org-calendar-auth-finished-hook)
(defvar my/org-calendar-auth-problem)
(defvar my/org-calendar-login-process)
(defvar my/org-calendar-keychain-enabled)
(defvar my/org-calendar-keychain-helper-file)
(defvar oauth2-auto-plstore)
(declare-function my/org-calendar-login "config")
(declare-function my/org-calendar-auto--schedule "org-calendar-auto")

(defconst my/org-calendar-keychain-service "org.doom-emacs.personal-calendar"
  "Keychain service used only for the local calendar store's unlock passphrase.")
(setq my/org-calendar-keychain-helper-file
      (expand-file-name "org-calendar-keychain" (file-name-directory my/org-calendar-settings-file)))
(defvar my/org-calendar-keychain-enabled-file
  (expand-file-name "org-calendar-keychain-enabled" (file-name-directory my/org-calendar-settings-file)))
(setq my/org-calendar-keychain-enabled (file-readable-p my/org-calendar-keychain-enabled-file))
(defvar my/org-calendar-keychain-process nil)
(defvar my/org-calendar-keychain-save-requested nil)

(defun my/org-calendar-keychain--process (operation passphrase callback)
  "Run native OPERATION asynchronously; send PASSPHRASE privately, then CALLBACK."
  (unless (and (eq system-type 'darwin) (file-executable-p my/org-calendar-keychain-helper-file))
    (user-error "Calendar Keychain helper is missing; run SPC n g k to build it"))
  (when (and my/org-calendar-keychain-process (process-live-p my/org-calendar-keychain-process))
    (user-error "A calendar Keychain operation is already running"))
  (let ((process
         (make-process
          :name "org-calendar-keychain" :buffer nil :stderr nil
          :connection-type 'pipe :coding 'utf-8-unix :noquery t
          :command (list my/org-calendar-keychain-helper-file operation
                         my/org-calendar-keychain-service (file-truename oauth2-auto-plstore))
          :filter (lambda (_process _output))
          :sentinel (lambda (process _event)
                      (when (memq (process-status process) '(exit signal failed))
                        (when-let* ((timer (process-get process 'timeout-timer))) (cancel-timer timer))
                        (when (eq process my/org-calendar-keychain-process)
                          (setq my/org-calendar-keychain-process nil))
                        (funcall callback (= (process-exit-status process) 0)))))))
    (setq my/org-calendar-keychain-process process)
    (when passphrase (process-send-string process passphrase))
    (process-send-eof process)
    (process-put process 'timeout-timer (run-at-time 120 nil #'delete-process process))))

(defun my/org-calendar-keychain--remember (success _background)
  "Save the unlock only after SUCCESS proves the entered passphrase works."
  (when my/org-calendar-keychain-save-requested
    (setq my/org-calendar-keychain-save-requested nil)
    (if (not (and success my/org-calendar-token-passphrase))
        (message "Keychain setup wasn't completed; no passphrase was stored")
      (my/org-calendar-keychain--process
       "put" my/org-calendar-token-passphrase
       (lambda (saved)
         (if (not saved)
             (message "Keychain storage failed; calendar remains unlocked only in this session")
           ;; Persist only the opt-in flag, never the secret, outside tracked files.
           (write-region "enabled\n" nil my/org-calendar-keychain-enabled-file nil 'silent)
           (set-file-modes my/org-calendar-keychain-enabled-file #o600)
           (setq my/org-calendar-keychain-enabled t)
           (message "Calendar Keychain unlock enabled; future Emacs sessions resume automatically")
           (when (fboundp 'my/org-calendar-auto--schedule) (my/org-calendar-auto--schedule))))))))

(defun my/org-calendar-keychain-build ()
  "Build the helper without blocking Emacs; requires Apple command-line tools."
  (interactive)
  (unless (eq system-type 'darwin) (user-error "Calendar Keychain integration requires macOS"))
  (let* ((source (expand-file-name "org-calendar-keychain.swift"
                                  (file-name-directory my/org-calendar-auth-worker-file)))
         (output (concat my/org-calendar-keychain-helper-file ".new")))
    (make-process
     :name "org-calendar-keychain-build" :buffer "*Calendar Keychain Build*" :noquery t
     :command (list "/usr/bin/xcrun" "swiftc" "-O" source "-o" output)
     :sentinel (lambda (process _event)
                 (when (memq (process-status process) '(exit signal failed))
                   (if (not (= (process-exit-status process) 0))
                       (message "Keychain helper build failed; see *Calendar Keychain Build*")
                     (set-file-modes output #o700)
                     (rename-file output my/org-calendar-keychain-helper-file t)
                     (message "Keychain helper ready; run SPC n g k to finish setup")))))
    (message "Building calendar Keychain helper in the background")))

(defun my/org-calendar-keychain-enable ()
  "Validate the local unlock, then store it in macOS Keychain with user consent."
  (interactive)
  (if (not (file-executable-p my/org-calendar-keychain-helper-file))
      (my/org-calendar-keychain-build)
    (when (and my/org-calendar-keychain-process (process-live-p my/org-calendar-keychain-process))
      (user-error "A calendar Keychain operation is already running"))
    (when (and my/org-calendar-login-process (process-live-p my/org-calendar-login-process))
      (user-error "Calendar login is already running; wait for it or cancel with SPC n g m c"))
    ;; Let explicit setup prompt for the existing passphrase, even if an old item exists.
    (setq my/org-calendar-keychain-save-requested t)
    (condition-case failure
        (let ((my/org-calendar-keychain-enabled nil))
          (my/org-calendar-login))
      ((error quit)
       (setq my/org-calendar-keychain-save-requested nil)
       (signal (car failure) (cdr failure))))))

(defun my/org-calendar-keychain-disable ()
  "Forget only this calendar's Keychain item; keep encrypted tokens and Org files."
  (interactive)
  (when (and my/org-calendar-keychain-process (process-live-p my/org-calendar-keychain-process))
    (user-error "Wait for the current Keychain operation to finish"))
  (when (yes-or-no-p "Forget the calendar unlock stored in macOS Keychain? ")
    (setq my/org-calendar-keychain-enabled nil my/org-calendar-keychain-save-requested nil)
    (when (file-exists-p my/org-calendar-keychain-enabled-file)
      (delete-file my/org-calendar-keychain-enabled-file))
    (my/org-calendar-keychain--process
     "delete" nil (lambda (deleted)
                    (message (if deleted "Calendar Keychain item removed; encrypted tokens and events kept"
                               "Automatic Keychain unlock disabled, but removing the item failed"))))))

(add-hook 'my/org-calendar-auth-finished-hook #'my/org-calendar-keychain--remember)
(provide 'org-calendar-keychain)
