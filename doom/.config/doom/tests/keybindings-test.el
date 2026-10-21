;;; keybindings-test.el --- Literate keybinding checks -*- lexical-binding: t; -*-
;; emacs -Q --batch -l tests/keybindings-test.el -f ert-run-tests-batch-and-exit
(require 'ert)

(defconst my/keybinding-test-config
  (expand-file-name "../config.org" (file-name-directory load-file-name)))

(defun my/keybinding-test-form (start)
  "Read the binding form beginning with START, without loading Doom."
  (with-temp-buffer
    (setq-local case-fold-search nil)
    (insert-file-contents my/keybinding-test-config)
    (goto-char (point-min))
    (search-forward start)
    (goto-char (match-beginning 0))
    (read (current-buffer))))

(defun my/keybinding-test-binding (form key)
  "Read KEY's configured binding from FORM, requiring an explicit entry."
  (let ((entry (member key (cdr form))))
    (should entry)
    (cadr entry)))

(ert-deftest my/keybindings-theme-toggle-uses-lowercase-and-removes-old-alias ()
  (let ((form (my/keybinding-test-form "(map! :leader\n      \"t D\" nil")))
    (should (equal (my/keybinding-test-binding form "t u") '(function my/toggle-theme)))
    (should-not (my/keybinding-test-binding form "t D"))
    (should-not (member "t d" form))
    (should (equal (my/keybinding-test-binding form "t t") '(function toggle-truncate-lines)))))

(ert-deftest my/keybindings-agent-shell-name-and-fork-use-lowercase-without-aliases ()
  (let ((form (my/keybinding-test-form "(map! :map agent-shell-mode-map\n        :localleader")))
    (should (equal (my/keybinding-test-binding form "n") '(function agent-shell-hq-label)))
    (should (equal (my/keybinding-test-binding form "f") '(function agent-shell-fork)))
    (should-not (my/keybinding-test-binding form "N"))
    (should-not (my/keybinding-test-binding form "F"))
    (should (equal (my/keybinding-test-binding form "r") '(function agent-shell-reload)))
    (should (equal (my/keybinding-test-binding form "R") '(function agent-shell-restart)))))

(ert-deftest my/keybindings-documentation-does-not-suggest-retired-keys ()
  (with-temp-buffer
    (setq-local case-fold-search nil)
    (insert-file-contents my/keybinding-test-config)
    (dolist (key '("SPC t D" ", N" ", F" "SPC l N"))
      (goto-char (point-min))
      (should-not (search-forward key nil t)))))

(provide 'keybindings-test)
