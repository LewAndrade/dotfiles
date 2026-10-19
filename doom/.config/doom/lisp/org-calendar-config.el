;;; org-calendar-config.el --- Explicit personal calendar approval -*- lexical-binding: t; -*-

(require 'subr-x)
(require 'cl-lib)
(require 'seq)

(defvaralias 'my/org-gcal-test-calendar-id 'my/org-calendar-id)
(defvar my/org-calendar-id nil
  "Canonical Google ID of the configured personal calendar, never `primary'.")
(defvar my/org-calendar-approved-primary-id nil
  "Exact primary calendar ID explicitly approved in private local settings.
Leave nil to allow secondary calendars only. Never use the alias `primary'.")

(defun my/org-calendar-configured-id-p (calendar-id)
  "Allow a secondary CALENDAR-ID or the exact explicitly approved primary ID."
  (and (stringp calendar-id)
       (string-match-p "\\`[^@[:space:]/]+@[^@[:space:]/]+\\'" calendar-id)
       (or (string-suffix-p "@group.calendar.google.com" calendar-id)
           (equal calendar-id my/org-calendar-approved-primary-id))))

(defvar my/org-background-buffers nil
  "File buffers that background sync opened and nobody has looked at since.")

(defun my/org-background-buffer (file)
  "Return the buffer visiting FILE, remembering it if we had to open it."
  (or (get-file-buffer file)
      (let ((buffer (find-file-noselect file)))
        (cl-pushnew buffer my/org-background-buffers)
        buffer)))

(defun my/org-background-release (file)
  "Kill FILE's buffer if background sync opened it and no one has used it.
Keep it when it has unsaved edits, was ever shown in a window, or an Org agenda
may still hold markers into it."
  (setq my/org-background-buffers (seq-filter #'buffer-live-p my/org-background-buffers))
  (when-let* ((buffer (get-file-buffer file))
              ((memq buffer my/org-background-buffers))
              ((not (buffer-modified-p buffer)))
              ((zerop (buffer-local-value 'buffer-display-count buffer)))
              ((not (get-buffer-window buffer t)))
              ((not (seq-some (lambda (other)
                                (with-current-buffer other (derived-mode-p 'org-agenda-mode)))
                              (buffer-list))))
              ((kill-buffer buffer)))
    (setq my/org-background-buffers (delq buffer my/org-background-buffers))))

(provide 'org-calendar-config)
