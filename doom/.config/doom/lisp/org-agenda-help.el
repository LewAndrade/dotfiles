;;; org-agenda-help.el --- A which-key style menu of agenda keys -*- lexical-binding: t; -*-

;; `?' in an Org agenda opens a transient menu of the keys worth knowing,
;; grouped in columns. Each key is the one the agenda itself uses (evil-org's
;; motion state, plus Doom's `,' local leader), so the menu teaches the real
;; binding, and pressing it in the menu runs it. Movement and marking keep the
;; menu open; everything else runs and closes it.

(require 'transient)

(defconst my/org-agenda-help-groups
  '(("Move"
     ("j" org-agenda-next-line "next line" t)
     ("k" org-agenda-previous-line "previous line" t)
     ("gj" org-agenda-next-item "next item" t)
     ("gk" org-agenda-previous-item "previous item" t)
     ("[" org-agenda-earlier "earlier day/week" t)
     ("]" org-agenda-later "later day/week" t)
     ("." org-agenda-goto-today "today" t)
     ("gd" org-agenda-goto-date "go to a date"))
    ("View"
     ("gD" org-agenda-view-mode-dispatch "day/week/month/log…")
     ("gr" org-agenda-redo "refresh")
     ("gR" org-agenda-redo-all "refresh all")
     ("C-SPC" org-agenda-show-and-scroll-up "peek at entry" t)
     (", v" my/org-agenda-toggle-centering "centre Today on/off")
     ("sc" org-agenda-filter-by-category "filter: Work/Personal")
     ("st" org-agenda-filter-by-tag "filter: tag")
     ("sr" org-agenda-filter-by-regexp "filter: text")
     ("S" org-agenda-filter-remove-all "clear filters"))
    ("Task"
     ("t" org-agenda-todo "change state")
     (", d s" org-agenda-schedule "schedule")
     (", d d" org-agenda-deadline "deadline")
     ("H" org-agenda-do-date-earlier "date −1 day" t)
     ("L" org-agenda-do-date-later "date +1 day" t)
     (", q" org-agenda-set-tags "tags")
     (", p p" org-agenda-priority "priority")
     ("ce" org-agenda-set-effort "effort")
     ("a" org-agenda-add-note "add a note")
     (", r" org-agenda-refile "refile")
     ("dA" org-agenda-archive "archive")
     ("dd" org-agenda-kill "delete"))
    ("Open"
     ("RET" org-agenda-switch-to "open here")
     ("TAB" org-agenda-goto "open beside")
     ("C" org-agenda-capture "capture on this date")
     (", e" my/org-calendar-repeat-edit "edit event"))
    ("Clock and bulk"
     ("I" org-agenda-clock-in "clock in")
     ("O" org-agenda-clock-out "clock out")
     ("cg" org-agenda-clock-goto "go to clocked task")
     ("m" org-agenda-bulk-toggle "mark/unmark" t)
     ("*" org-agenda-bulk-mark-all "mark all" t)
     ("U" org-agenda-bulk-unmark-all "unmark all" t)
     ("x" org-agenda-bulk-action "act on marked"))
    ("Other"
     ("u" org-agenda-undo "undo")
     ("q" org-agenda-quit "quit")
     ("ZQ" org-agenda-exit "quit and close files")))
  "Agenda keys shown by `my/org-agenda-help': (KEY COMMAND LABEL STAY-OPEN).")

(defun my/org-agenda-help--layout ()
  "Return the transient columns, skipping commands that are not defined."
  (apply #'vector
         (mapcar (lambda (group)
                   (apply #'vector (car group)
                          (delq nil
                                (mapcar (lambda (entry)
                                          (pcase-let ((`(,key ,command ,label ,stay) entry))
                                            (when (fboundp command)
                                              (list key label command :transient (and stay t)))))
                                        (cdr group)))))
                 my/org-agenda-help-groups)))

(defun my/org-agenda-help ()
  "Show the agenda keys worth knowing as a menu; any key in it runs too."
  (interactive)
  (unless (commandp 'my/org-agenda-help-menu)
    (eval `(transient-define-prefix my/org-agenda-help-menu ()
             "Agenda keys."
             ,(my/org-agenda-help--layout))
          t))
  (call-interactively #'my/org-agenda-help-menu))

(with-eval-after-load 'evil-org-agenda
  ;; `?' was a backward search, which `/' and `n'/`N' already cover in a list.
  (evil-define-key* 'motion evil-org-agenda-mode-map "?" #'my/org-agenda-help))

(provide 'org-agenda-help)
;;; org-agenda-help.el ends here
