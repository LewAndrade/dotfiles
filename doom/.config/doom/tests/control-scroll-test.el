;;; control-scroll-test.el -*- lexical-binding: t; -*-
;; emacs -Q --batch -l tests/control-scroll-test.el -f ert-run-tests-batch-and-exit
(require 'ert)
(require 'seq)
(require 'mwheel)

(with-temp-buffer
  (insert-file-contents
   (expand-file-name "../config.org" (file-name-directory load-file-name)))
  (goto-char (point-min))
  (re-search-forward "^(defun my/disable-control-scroll-zoom")
  (goto-char (match-beginning 0))
  (eval (read (current-buffer)) t))

(ert-deftest my/control-scroll-disables-local-and-global-zoom ()
  (let ((global-map (copy-keymap (current-global-map)))
        (mouse-wheel-scroll-amount
         '(2 ((shift) . hscroll) ((meta) . nil)
             ((control) . text-scale) ((control meta) . global-text-scale))))
    (dolist (key '("C-<wheel-up>" "C-<wheel-down>" "C-<mouse-4>" "C-<mouse-5>"
                   "C-M-<wheel-up>" "C-M-<wheel-down>" "C-M-<mouse-4>" "C-M-<mouse-5>"))
      (define-key global-map (kbd key) #'mouse-wheel-text-scale))
    (let ((original-map (current-global-map)))
      (unwind-protect
          (progn
            (use-global-map global-map)
            (my/disable-control-scroll-zoom)
            (my/disable-control-scroll-zoom)
            (should (equal mouse-wheel-scroll-amount
                           '(2 ((shift) . hscroll) ((meta) . nil))))
            (dolist (key '("C-<wheel-up>" "C-<wheel-down>" "C-<mouse-4>" "C-<mouse-5>"
                           "C-M-<wheel-up>" "C-M-<wheel-down>" "C-M-<mouse-4>" "C-M-<mouse-5>"))
              (should (eq (lookup-key global-map (kbd key)) #'ignore))))
        (use-global-map original-map)))))

(ert-deftest my/control-scroll-preserves-ordinary-scrolling-and-keyboard-zoom ()
  (let* ((original-map (current-global-map))
         (test-map (copy-keymap original-map))
         (mouse-wheel-scroll-amount '(2 ((shift) . hscroll)))
         (keys '("<wheel-up>" "<wheel-down>" "S-<wheel-up>" "S-<wheel-down>"
                 "C-x C-+" "C-x C--")))
    (unwind-protect
        (progn
          (use-global-map test-map)
          (my/disable-control-scroll-zoom)
          (should (equal mouse-wheel-scroll-amount '(2 ((shift) . hscroll))))
          (dolist (key keys)
            (should (equal (lookup-key test-map (kbd key))
                           (lookup-key original-map (kbd key))))))
      (use-global-map original-map))))
