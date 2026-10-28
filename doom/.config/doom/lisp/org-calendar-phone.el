;;; org-calendar-phone.el --- Read-only calendar copy for Bloom on the phone -*- lexical-binding: t; -*-

;; A recurring series in calendar-personal.org stores only its first date and
;; a Google RRULE, which Bloom cannot expand. This module
;; writes `calendar-phone.org': one heading per occurrence in a rolling
;; window, each with a bare active timestamp on the line Bloom reads. Emacs
;; owns the file and rewrites it, so edits made to it are lost. It is not an
;; agenda file, so the Emacs agenda never shows an event twice.

(require 'calendar)
(require 'subr-x)
(declare-function my/org-file "config" (name))
(declare-function my/org-background-call "org-calendar-config" (fn &rest args))
;; Loaded by config.org from org-calendar-view.el, which is not on `load-path'.
(declare-function my/org-calendar-view--org-events "org-calendar-view" (start end))
(declare-function my/org-calendar-view--occurrences "org-calendar-view" (start end))
(declare-function org-timegrid-event-start "org-timegrid-model" (event))
(declare-function org-timegrid-event-end "org-timegrid-model" (event))
(declare-function org-timegrid-event-all-day "org-timegrid-model" (event))
(declare-function org-timegrid-event-title "org-timegrid-model" (event))
(declare-function org-timegrid-event-source "org-timegrid-model" (event))

(defvar my/org-calendar-phone-days-before 1
  "Days before today to include, so a just-passed event stays visible.")

(defvar my/org-calendar-phone-days-after 60
  "Days after today to include.")

(defvar my/org-calendar-phone--timer nil)
(defvar my/org-calendar-phone--debounce nil)

(defun my/org-calendar-phone--file ()
  (my/org-file "calendar-phone.org"))

(defun my/org-calendar-phone--stamp (minute &optional with-time)
  "Format absolute MINUTE as an Org date, with HH:MM when WITH-TIME."
  (let* ((date (calendar-gregorian-from-absolute (/ minute 1440)))
         (time (encode-time 0 0 12 (nth 1 date) (car date) (nth 2 date)))
         (system-time-locale "C"))
    (concat (format-time-string "%Y-%m-%d %a" time)
            (when with-time
              (format " %02d:%02d" (/ (% minute 1440) 60) (% minute 60))))))

(defun my/org-calendar-phone--timestamp (event)
  "Return the active Org timestamp for EVENT, a `org-timegrid-event'."
  (let* ((start (org-timegrid-event-start event))
         (end (max start (org-timegrid-event-end event))))
    (if (org-timegrid-event-all-day event)
        ;; All-day ends are exclusive: an event on the 7th ends at the 8th's 00:00.
        (let ((last (max start (- end 1440))))
          (if (= (/ last 1440) (/ start 1440))
              (format "<%s>" (my/org-calendar-phone--stamp start))
            (format "<%s>--<%s>" (my/org-calendar-phone--stamp start)
                    (my/org-calendar-phone--stamp last))))
      (if (= (/ start 1440) (/ end 1440))
          (format "<%s-%02d:%02d>" (my/org-calendar-phone--stamp start t)
                  (/ (% end 1440) 60) (% end 60))
        (format "<%s>--<%s>" (my/org-calendar-phone--stamp start t)
                (my/org-calendar-phone--stamp end t))))))

(defun my/org-calendar-phone--events ()
  "Personal single events and expanded recurring occurrences in the window."
  (let* ((today (calendar-absolute-from-gregorian (calendar-current-date)))
         (start (* (- today my/org-calendar-phone-days-before) 1440))
         (end (* (+ today my/org-calendar-phone-days-after 1) 1440))
         (personal (my/org-file "calendar-personal.org"))
         (singles (seq-filter
                   (lambda (event)
                     (let ((marker (plist-get (org-timegrid-event-source event) :heading-marker)))
                       (and (markerp marker) (marker-buffer marker)
                            (equal (buffer-file-name (marker-buffer marker)) personal))))
                   (my/org-calendar-view--org-events start end))))
    (seq-sort-by #'org-timegrid-event-start #'<
                 (append singles (my/org-calendar-view--occurrences start end)))))

(defun my/org-calendar-phone--render (events)
  (concat
   "#+title: Calendar\n#+category: Calendar\n#+startup: overview\n\n"
   "# Read-only copy of calendar-personal.org for Bloom, written by Emacs.\n"
   "# Changes here are overwritten. Create and edit events in Google Calendar or Emacs.\n"
   (mapconcat
    (lambda (event)
      (format "\n* %s\n%s\n"
              (string-trim (replace-regexp-in-string
                            "[\n\r]+" " " (or (org-timegrid-event-title event) "busy")))
              (my/org-calendar-phone--timestamp event)))
    events "")))

(defun my/org-calendar-phone-export ()
  "Write `calendar-phone.org' when its contents change. Never touches the network.
Org files it has to open are closed again, so the timer leaves no buffers behind."
  (interactive)
  (condition-case err
      (let* ((file (my/org-calendar-phone--file))
             (content (my/org-calendar-phone--render
                       (my/org-background-call #'my/org-calendar-phone--events)))
             (old (and (file-readable-p file)
                       (with-temp-buffer (insert-file-contents file) (buffer-string)))))
        ;; An unchanged file is left alone, so Syncthing has nothing to send.
        (unless (equal content old)
          (let ((coding-system-for-write 'utf-8-unix))
            (write-region content nil file nil 'silent)))
        (when (called-interactively-p 'interactive)
          (message "Calendar copy for Bloom: %s" (if (equal content old) "unchanged" "written"))))
    (error (message "Calendar copy for Bloom failed: %s" (error-message-string err)))))

(defun my/org-calendar-phone--after-save-h ()
  "Re-export soon after the calendar sync saves `calendar-personal.org'."
  (when (and buffer-file-name
             (equal (expand-file-name buffer-file-name) (my/org-file "calendar-personal.org")))
    (when (timerp my/org-calendar-phone--debounce)
      (cancel-timer my/org-calendar-phone--debounce))
    (setq my/org-calendar-phone--debounce
          (run-at-time 3 nil #'my/org-calendar-phone-export))))

(define-minor-mode my/org-calendar-phone-mode
  "Keep `calendar-phone.org' current: after calendar saves, and every 10 minutes.
The timer also rolls the window forward at the start of a new day."
  :global t
  (when (timerp my/org-calendar-phone--timer)
    (cancel-timer my/org-calendar-phone--timer))
  (setq my/org-calendar-phone--timer nil)
  (remove-hook 'after-save-hook #'my/org-calendar-phone--after-save-h)
  (when my/org-calendar-phone-mode
    (add-hook 'after-save-hook #'my/org-calendar-phone--after-save-h)
    (setq my/org-calendar-phone--timer
          (run-at-time 30 600 #'my/org-calendar-phone-export))))

(provide 'org-calendar-phone)
;;; org-calendar-phone.el ends here
