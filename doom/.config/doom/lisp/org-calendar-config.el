;;; org-calendar-config.el --- Explicit personal calendar approval -*- lexical-binding: t; -*-

(require 'subr-x)

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

(provide 'org-calendar-config)
