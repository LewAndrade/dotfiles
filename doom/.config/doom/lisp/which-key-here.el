;;; which-key-here.el --- Show which prefixes exist in this buffer -*- lexical-binding: t; -*-

;; which-key explains a prefix once you press it, but not which prefixes exist.
;; `my/which-key-prefixes-here' collects every prefix key active in the current
;; buffer (evil state maps, the major mode, minor modes, the leader), and shows
;; them in a which-key popup with their usual names. Press one and it acts as
;; if typed: which-key takes over from there, as with any prefix. C-g closes.

(require 'which-key)

(defvar my/which-key-here-map (make-sparse-keymap)
  "Prefix keys of the buffer `my/which-key-prefixes-here' was called from.")

(defun my/which-key-here--ignored-p (event)
  "Non-nil for events that are not keys a person types."
  (or (not (or (integerp event) (symbolp event)))
      (memq event '(menu-bar tool-bar tab-bar header-line mode-line remap
                    vertical-line vertical-scroll-bar horizontal-scroll-bar
                    left-fringe right-fringe left-margin right-margin))
      ;; ESC is the Meta prefix, already reachable as M- keys.
      (eq event 27)
      (and (symbolp event)
           (string-match-p
            (concat "mouse\\|wheel\\|drag\\|touch\\|pinch\\|state\\'\\|corner"
                    "\\|edge\\|divider\\|tab-line\\|\\`f[0-9]+\\'\\|\\`help\\'")
            (symbol-name event)))))

(defun my/which-key-here--collect (buffer)
  "Return an alist of (EVENT . PREFIX-MAP) active in BUFFER, first map wins."
  (with-current-buffer buffer
    (let (prefixes)
      (dolist (map (current-active-maps t))
        (map-keymap
         (lambda (event definition)
           (unless (or (my/which-key-here--ignored-p event) (assq event prefixes))
             ;; Look up through the active maps, so an evil state map or the
             ;; leader shadows a global prefix exactly as the real key would.
             (let ((binding (key-binding (vector event) t)))
               (when (keymapp binding)
                 (push (cons event binding) prefixes)))))
         map))
      (nreverse prefixes))))

(defun my/which-key-prefixes-here ()
  "Show the prefix keys available in this buffer; press one to explore it."
  (interactive)
  (let ((buffer (current-buffer))
        (map (make-sparse-keymap)))
    (pcase-dolist (`(,event . ,prefix) (my/which-key-here--collect buffer))
      (define-key map (vector event) prefix))
    (setq my/which-key-here-map map)
    (which-key--show-keymap "Prefixes here" map nil nil t)
    ;; Hand the chosen key back to the command loop, so it acts exactly as if
    ;; typed: which-key then shows that prefix, and the final key really runs.
    (let ((key (read-key)))
      (which-key--hide-popup)
      (unless (memq key '(?\C-g escape))
        (setq unread-command-events (list key))))))

(provide 'which-key-here)
;;; which-key-here.el ends here
