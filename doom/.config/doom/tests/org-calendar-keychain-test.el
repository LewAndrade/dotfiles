;;; org-calendar-keychain-test.el -*- lexical-binding: t; -*-
(load (expand-file-name "org-calendar-auto-test.el" (file-name-directory load-file-name)) nil t)
(load (expand-file-name "../lisp/org-calendar-keychain.el" (file-name-directory load-file-name)) nil t)

(defmacro my/calendar-keychain-test-workspace (&rest body)
  (declare (indent 0))
  `(let* ((directory (make-temp-file "calendar-keychain-test-" t))
          (my/org-calendar-settings-file (expand-file-name "settings.el" directory))
          (oauth2-auto-plstore (expand-file-name "tokens.plist" directory))
          (my/org-calendar-keychain-helper-file (expand-file-name "helper" directory))
          (my/org-calendar-keychain-enabled-file (expand-file-name "enabled" directory))
          (my/org-calendar-keychain-enabled nil)
          (my/org-calendar-keychain-save-requested nil)
          (my/org-calendar-keychain-process nil)
          (my/org-calendar-login-process nil)
          (my/org-calendar-token-passphrase nil)
          (my/org-calendar-access-token nil)
          (my/org-calendar-token-expiration nil)
          (my/org-calendar-auth-problem nil)
          (my/org-calendar-auth-retry-after 0)
          (my/org-calendar-auth-finished-hook nil))
     (unwind-protect (progn ,@body) (delete-directory directory t))))

(ert-deftest my/calendar-keychain-remembers-only-a-validated-unlock ()
  (my/calendar-keychain-test-workspace
    (let ((my/org-calendar-token-passphrase (copy-sequence "fake-private-passphrase")) stored)
      (cl-letf (((symbol-function 'my/org-calendar-keychain--process)
                 (lambda (operation passphrase callback)
                   (setq stored (list operation passphrase)) (funcall callback t)))
                ((symbol-function 'my/org-calendar-auto--schedule) #'ignore))
        (setq my/org-calendar-keychain-save-requested t)
        (my/org-calendar-keychain--remember nil nil)
        (should-not stored)
        (should-not (file-exists-p my/org-calendar-keychain-enabled-file))
        (setq my/org-calendar-keychain-save-requested t)
        (my/org-calendar-keychain--remember t nil)
        (should (equal stored '("put" "fake-private-passphrase")))
        (should my/org-calendar-keychain-enabled)
        (should (= (logand (file-modes my/org-calendar-keychain-enabled-file) #o777) #o600))
        (with-temp-buffer
          (insert-file-contents my/org-calendar-keychain-enabled-file)
          (should (equal (buffer-string) "enabled\n")))))))

(ert-deftest my/calendar-keychain-save-failure-does-not-enable-auto-unlock ()
  (my/calendar-keychain-test-workspace
    (let ((my/org-calendar-token-passphrase (copy-sequence "fake-private-passphrase")))
      (cl-letf (((symbol-function 'my/org-calendar-keychain--process)
                 (lambda (_operation _passphrase callback) (funcall callback nil))))
        (setq my/org-calendar-keychain-save-requested t)
        (my/org-calendar-keychain--remember t nil)
        (should-not my/org-calendar-keychain-enabled)
        (should-not (file-exists-p my/org-calendar-keychain-enabled-file))
        (should (equal my/org-calendar-token-passphrase "fake-private-passphrase"))))))

(ert-deftest my/calendar-keychain-background-startup-never-prompts-for-the-passphrase ()
  (my/calendar-keychain-test-workspace
    (let ((my/org-calendar-keychain-enabled t) launched)
      (cl-letf (((symbol-function 'file-executable-p) (lambda (_) t))
                ((symbol-function 'read-passwd) (lambda (&rest _) (ert-fail "Startup must not prompt")))
                ((symbol-function 'my/org-calendar--launch-login)
                 (lambda (passphrase background) (setq launched (list passphrase background)))))
        (should (my/org-calendar-unlock-available-p))
        (my/org-calendar-background-refresh)
        (should (equal launched '(nil t)))
        (should-not my/org-calendar-token-passphrase)))))

(ert-deftest my/calendar-keychain-explicit-login-can-reuse-keychain-without-a-prompt ()
  (my/calendar-keychain-test-workspace
    (let ((my/org-calendar-keychain-enabled t) launched)
      (cl-letf (((symbol-function 'file-executable-p) (lambda (_) t))
                ((symbol-function 'file-readable-p) (lambda (_) t))
                ((symbol-function 'my/org-calendar-prepare) #'ignore)
                ((symbol-function 'my/org-calendar-show-login-status) #'ignore)
                ((symbol-function 'read-passwd) (lambda (&rest _) (ert-fail "Unlock lives in Keychain")))
                ((symbol-function 'my/org-calendar--launch-login)
                 (lambda (passphrase &optional background) (setq launched (list passphrase background)))))
        (my/org-calendar-login)
        (should (equal launched '(nil nil)))))))

(ert-deftest my/calendar-keychain-setup-prompts-instead-of-reusing-an-old-keychain-item ()
  (my/calendar-keychain-test-workspace
    (let ((my/org-calendar-keychain-enabled t) prompted launched)
      (cl-letf (((symbol-function 'file-executable-p) (lambda (_) t))
                ((symbol-function 'file-readable-p) (lambda (_) t))
                ((symbol-function 'my/org-calendar-prepare) #'ignore)
                ((symbol-function 'my/org-calendar-show-login-status) #'ignore)
                ((symbol-function 'read-passwd)
                 (lambda (&rest _) (setq prompted t) (copy-sequence "fake-private-passphrase")))
                ((symbol-function 'my/org-calendar--launch-login)
                 (lambda (passphrase &optional _background) (setq launched (copy-sequence passphrase)))))
        (my/org-calendar-keychain-enable)
        (should prompted)
        (should (equal launched "fake-private-passphrase"))
        (should my/org-calendar-keychain-save-requested)))))

(ert-deftest my/calendar-keychain-adapter-sends-the-secret-through-stdin-not-arguments ()
  (my/calendar-keychain-test-workspace
    (let (options input eof)
      (cl-letf (((symbol-function 'file-executable-p) (lambda (_) t))
                ((symbol-function 'make-process) (lambda (&rest args) (setq options args) 'fake-process))
                ((symbol-function 'process-send-string) (lambda (_process text) (setq input text)))
                ((symbol-function 'process-send-eof) (lambda (_) (setq eof t)))
                ((symbol-function 'process-put) #'ignore)
                ((symbol-function 'run-at-time) #'ignore))
        (my/org-calendar-keychain--process "put" "fake-private-passphrase" #'ignore)
        (should (equal input "fake-private-passphrase"))
        (should eof)
        (should-not (plist-get options :buffer))
        (should-not (string-match-p "fake-private-passphrase" (prin1-to-string (plist-get options :command))))))))

(ert-deftest my/calendar-keychain-disabling-removes-only-its-opt-in-and-keychain-item ()
  (my/calendar-keychain-test-workspace
    (let ((my/org-calendar-keychain-enabled t)
          (my/org-calendar-access-token "fake-current-token") operation)
      (write-region "enabled\n" nil my/org-calendar-keychain-enabled-file nil 'silent)
      (write-region "fake encrypted store placeholder" nil oauth2-auto-plstore nil 'silent)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t))
                ((symbol-function 'my/org-calendar-keychain--process)
                 (lambda (action passphrase callback)
                   (setq operation (list action passphrase)) (funcall callback t))))
        (my/org-calendar-keychain-disable)
        (should (equal operation '("delete" nil)))
        (should-not my/org-calendar-keychain-enabled)
        (should-not (file-exists-p my/org-calendar-keychain-enabled-file))
        (should (file-exists-p oauth2-auto-plstore))
        (should (equal my/org-calendar-access-token "fake-current-token"))))))

(ert-deftest my/calendar-keychain-worker-fails-safely-when-the-item-is-unavailable ()
  (skip-unless (locate-library "org-gcal"))
  (my/calendar-keychain-test-workspace
    (write-region "#!/bin/sh\nexit 3\n" nil my/org-calendar-keychain-helper-file nil 'silent)
    (set-file-modes my/org-calendar-keychain-helper-file #o700)
    (write-region "" nil my/org-calendar-settings-file nil 'silent)
    (with-temp-buffer
      (should (= 1 (call-process
                    (expand-file-name invocation-name invocation-directory)
                    nil t nil "-Q" "--batch" "--eval" (prin1-to-string `(setq load-path ',load-path))
                    "-l" my/org-calendar-test-worker-file "--" my/org-calendar-settings-file
                    oauth2-auto-plstore "refresh-only" "keychain" my/org-calendar-keychain-helper-file)))
      (should (string-match-p "ORG-CALENDAR ERROR keychain" (buffer-string)))
      (should-not (string-match-p "ORG-CALENDAR URL\\|ORG-CALENDAR TOKEN" (buffer-string))))))

(ert-deftest my/calendar-keychain-native-unlock-survives-fresh-workers-and-keeps-tokens-encrypted ()
  (skip-unless (and (eq system-type 'darwin) (file-executable-p my/org-calendar-keychain-helper-file)
                   (locate-library "org-gcal") (executable-find "gpg")))
  (let ((native-helper my/org-calendar-keychain-helper-file))
    (my/calendar-keychain-test-workspace
      (setq my/org-calendar-keychain-helper-file native-helper)
      (let ((account (file-truename oauth2-auto-plstore))
            (setup '(progn
                      (require 'org-gcal)
                      (defun oauth2-auto-plist (user provider)
                        (let* ((data (or (oauth2-auto--plstore-read user provider)
                                         (oauth2-auto--plstore-write
                                          user provider '(:access-token "fake-keychain-token"
                                                          :refresh-token "fake-private-refresh-token"
                                                          :expiration 4102444800))))
                               (promise (aio-promise)))
                          (aio-resolve promise (lambda () data)) promise))
                      (defun oauth2-auto--request (&rest _)
                        (let ((promise (aio-promise)))
                          (aio-resolve promise
                                       (lambda () '((access_token . "fake-renewed-token") (expires_in . 3600))))
                          promise)))))
        (unwind-protect
            (progn
              (with-temp-buffer
                (insert "dummy native keychain passphrase: 中文 and \"quotes\"")
                (should (= 0 (call-process-region
                              (point-min) (point-max) native-helper nil nil nil "put"
                              my/org-calendar-keychain-service account))))
              (write-region "(setq my/org-gcal-test-calendar-id \"test@group.calendar.google.com\")\n"
                            nil my/org-calendar-settings-file nil 'silent)
              (dolist (mode '("login" "refresh-only"))
                (with-temp-buffer
                  (should (= 0 (call-process
                                (expand-file-name invocation-name invocation-directory)
                                nil t nil "-Q" "--batch" "--eval" (prin1-to-string `(setq load-path ',load-path))
                                "--eval" (prin1-to-string setup) "-l" my/org-calendar-test-worker-file "--"
                                my/org-calendar-settings-file oauth2-auto-plstore mode "keychain" native-helper)))
                  (should (string-match-p "ORG-CALENDAR TOKEN" (buffer-string)))
                  (when (equal mode "refresh-only")
                    (should (string-match-p "fake-renewed-token" (buffer-string))))
                  (should-not (string-match-p "ORG-CALENDAR URL\\|dummy native\\|fake-private-refresh-token" (buffer-string)))))
              (with-temp-buffer
                (insert-file-contents oauth2-auto-plstore)
                (should (string-match-p "BEGIN PGP MESSAGE" (buffer-string)))
                (should-not (string-match-p "fake-keychain-token\\|fake-renewed-token\\|dummy native" (buffer-string)))))
          ;; Only the disposable store's Keychain item is deleted, never the real item.
          (should (= 0 (call-process native-helper nil nil nil "delete"
                                    my/org-calendar-keychain-service account))))))))
