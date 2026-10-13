;;; org-calendar-status.el --- Context-aware calendar status and mouse controls -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)
(require 'org)

(defvar my/org-calendar-auto-mode)
(defvar my/org-calendar-auto-status)
(defvar my/org-calendar-auto--file)
(defvar my/org-calendar-auto--last-error)
(defvar my/org-calendar-auth-problem)
(defvar my/org-calendar-login-process)
(defvar my/org-calendar-keychain-enabled)
(declare-function my/org-calendar-auto-review "org-calendar-auto" ())
(declare-function my/org-calendar-auto-mode "org-calendar-auto" (&optional arg))
(declare-function my/org-calendar-fetch "config" ())
(declare-function my/org-calendar-login "config" ())
(declare-function my/org-calendar-stop-login "config" ())
(declare-function my/org-calendar-keychain-enable "org-calendar-keychain" ())
(declare-function nerd-icons-faicon "nerd-icons" (name &rest args))
(declare-function nerd-icons-faicon-family "nerd-icons" ())

(defconst my/org-calendar-status-icons
  '(("up to date" "nf-fa-check_circle" "✓" success "Up to date")
    ("pending" "nf-fa-refresh" "↻" shadow "Pending or syncing")
    ("needs login" "nf-fa-lock" "?" warning "Login needed")
    ("needs attention" "nf-fa-exclamation_triangle" "!" error "Needs attention")
    ("paused" "nf-fa-pause_circle" "Ⅱ" shadow "Paused")
    ("retrying" "nf-fa-cloud" "!" warning "Sync failed; retrying automatically"))
  "State, Nerd Icon, fallback glyph, face, and readable tooltip label.")

(defun my/org-calendar-status-context-p ()
  "Recognize agenda, week, calendar-source, and calendar-control buffers."
  (or (derived-mode-p 'org-agenda-mode 'org-timegrid-mode)
      (member (buffer-name) '("*Personal Calendar Sync*" "*Personal Calendar Authorization*"))
      (string-prefix-p "*Recurring Occurrence Edit*" (buffer-name))
      (let ((file (buffer-file-name (or (buffer-base-buffer) (current-buffer)))))
        (and file
             (member (expand-file-name file)
                     (mapcar (lambda (name) (expand-file-name name org-directory))
                             '("calendar-personal.org" "calendar-work.org")))))))

(defun my/org-calendar-status-problem-p ()
  "Keep actionable status and failed retries visible outside calendar buffers."
  (or (member my/org-calendar-auto-status '("needs login" "needs attention"))
      (and (stringp my/org-calendar-auto--last-error)
           (not (string-empty-p my/org-calendar-auto--last-error)))
      (and (equal my/org-calendar-auto-status "pending")
           (memq my/org-calendar-auth-problem '(temporary keychain)))))

(defun my/org-calendar-status-state ()
  "Return the visible state without changing the sync engine's status."
  (cond ((not my/org-calendar-auto-mode) "paused")
        ((and (equal my/org-calendar-auto-status "pending")
              (my/org-calendar-status-problem-p)) "retrying")
        (t my/org-calendar-auto-status)))

(defun my/org-calendar-status--select-origin (event)
  "Select EVENT's modeline window, leaving its source point unchanged."
  (when event
    (let ((window (posn-window (event-start event))))
      (when (window-live-p window) (select-window window)))))

(defun my/org-calendar-status-open (&optional event)
  "Open the same status page as SPC n g s from a modeline EVENT."
  (interactive "e")
  (my/org-calendar-status--select-origin event)
  (my/org-calendar-auto-review))

(defun my/org-calendar-status-menu-map ()
  "Build mouse controls using the existing calendar commands and safeguards."
  (let ((map (make-sparse-keymap "Personal calendar"))
        (more (make-sparse-keymap "More"))
        (logging-in (and my/org-calendar-login-process
                         (process-live-p my/org-calendar-login-process))))
    (define-key map [status] '(menu-item "Status..." my/org-calendar-auto-review))
    (define-key map [login]
      `(menu-item "Login..." my/org-calendar-login :enable ,(not logging-in)))
    (define-key map [keychain]
      `(menu-item "Keychain setup..." my/org-calendar-keychain-enable
                  :enable ,(not my/org-calendar-keychain-enabled)))
    (define-key more [pause]
      `(menu-item ,(if my/org-calendar-auto-mode "Pause automatic sync" "Resume automatic sync")
                  my/org-calendar-auto-mode))
    ;; Never expose the old manual-fetch bypass while automation is paused.
    (define-key more [sync]
      `(menu-item "Sync now" my/org-calendar-fetch :enable ,my/org-calendar-auto-mode))
    (define-key more [cancel]
      `(menu-item "Cancel login" my/org-calendar-stop-login :enable ,logging-in))
    (define-key map [more] `(menu-item "More" ,more))
    map))

(defun my/org-calendar-status-menu (&optional event)
  "Open calendar mouse controls at EVENT; opening the menu makes no changes."
  (interactive "e")
  (my/org-calendar-status--select-origin event)
  (popup-menu (my/org-calendar-status-menu-map) event))

(defvar my/org-calendar-status-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'my/org-calendar-status-open)
    (define-key map [mode-line mouse-3] #'my/org-calendar-status-menu)
    map)
  "Click for status; right-click for the calendar controls.")

(defun my/org-calendar-status-icon (spec)
  "Render SPEC using Nerd Icons only when the icon font is available."
  (if (and (display-graphic-p) (require 'nerd-icons nil t)
           (find-font (font-spec :family (nerd-icons-faicon-family))))
      (nerd-icons-faicon (nth 1 spec) :height 1.0 :v-adjust 0.0 :face (nth 3 spec))
    (propertize (nth 2 spec) 'face (nth 3 spec))))

(defun my/org-calendar-status-render ()
  "Show one clickable icon in calendar context, or anywhere with a problem."
  (when (and my/org-calendar-auto--file
             (or (my/org-calendar-status-context-p) (my/org-calendar-status-problem-p)))
    (let* ((state (my/org-calendar-status-state))
           (spec (or (assoc state my/org-calendar-status-icons)
                     (list state "nf-fa-question_circle" "?" 'warning state)))
           (tooltip (concat "Personal calendar: " (nth 4 spec)
                            (when my/org-calendar-auto--last-error
                              (concat "\n" my/org-calendar-auto--last-error))
                            "\nLeft-click: Status (SPC n g s)\nRight-click: Calendar controls")))
      (propertize (concat " " (my/org-calendar-status-icon spec) " ")
                  'help-echo tooltip 'mouse-face 'mode-line-highlight
                  'local-map my/org-calendar-status-map))))

(defvar my/org-calendar-status-mode-line '(:eval (my/org-calendar-status-render))
  "Context-aware calendar modeline entry.")
(put 'my/org-calendar-status-mode-line 'risky-local-variable t)

(defun my/org-calendar-status-install ()
  "Replace only the previous Cal text indicator, keeping other modeline items."
  (setq global-mode-string
        (delete '(:eval (when my/org-calendar-auto-mode
                         (concat " Cal: " my/org-calendar-auto-status)))
                global-mode-string))
  (setq global-mode-string (delq 'my/org-calendar-status-mode-line global-mode-string))
  ;; A symbol as the first item makes global-mode-string a conditional form,
  ;; rather than a sequence. Store the :eval form itself, like the old entry.
  (add-to-list 'global-mode-string my/org-calendar-status-mode-line)
  (force-mode-line-update t))

(my/org-calendar-status-install)
(provide 'org-calendar-status)
