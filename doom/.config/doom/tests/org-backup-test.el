;;; org-backup-test.el --- Backup launcher checks -*- lexical-binding: t; -*-
;; Run: emacs -Q --batch -l tests/org-backup-test.el -f ert-run-tests-batch-and-exit
(require 'ert)
(require 'cl-lib)
(require 'subr-x)

;; Read only the launcher definitions, not the timer or other Doom settings.
(with-temp-buffer
  (insert-file-contents (expand-file-name "../config.org" (file-name-directory load-file-name)))
  (search-forward "(defvar my/org-backup-script")
  (goto-char (match-beginning 0))
  (let ((start (point))
        (end (progn (search-forward ";; Cancel first") (line-beginning-position))))
    (narrow-to-region start end)
    (goto-char (point-min))
    (while (progn (skip-chars-forward " \t\n\r") (< (point) (point-max)))
      (eval (read (current-buffer)) t))))

(ert-deftest my/org-backup-running-process-is-not-restarted-or-output-erased ()
  (let ((buffer (get-buffer-create " *org-backup*")))
    (unwind-protect
        (progn
          (with-current-buffer buffer (insert "Current backup output"))
          (cl-letf (((symbol-function 'get-process) (lambda (_) 'existing-process))
                    ((symbol-function 'process-live-p) (lambda (_) t))
                    ((symbol-function 'make-process) (lambda (&rest _) (ert-fail "Do not start another backup"))))
            (my/org-backup))
          (with-current-buffer buffer (should (equal (buffer-string) "Current backup output"))))
      (kill-buffer buffer))))

(ert-deftest my/org-backup-new-run-stays-asynchronous ()
  (let ((my/org-backup-script "/disposable/org-backup") call)
    (unwind-protect
        (cl-letf (((symbol-function 'get-process) (lambda (_) nil))
                  ((symbol-function 'file-executable-p) (lambda (_) t))
                  ((symbol-function 'make-process) (lambda (&rest args) (setq call args))))
          (my/org-backup)
          (should (equal (plist-get call :command) '("/disposable/org-backup")))
          (should (plist-get call :noquery))
          (should (functionp (plist-get call :sentinel))))
      (when-let* ((buffer (get-buffer " *org-backup*"))) (kill-buffer buffer)))))
