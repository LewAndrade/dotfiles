;;; org-calendar-view.el --- Read-only SVG week for the central Org files -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'org)
(require 'org-element)
(require 'org-timegrid-org)
(require 'iso8601)
(require 'parse-time)
(declare-function parse-iso8601-time-string "parse-time" (date))
(declare-function set-popup-rule! "doom-ui-popup" (predicate &rest plist))

(declare-function my/org-file "config" (name))
(declare-function my/org-calendar-repeat--effective-events "org-calendar-repeat" ())
(declare-function my/org-calendar-repeat--series-marker "org-calendar-repeat" (id))
(declare-function my/org-calendar-repeat--ensure-state "org-calendar-repeat" ())
(declare-function my/org-calendar-auto--same-file-p "org-calendar-auto" (file))
(defvar my/org-calendar-auto--calendar)
(defvar my/org-calendar-id)
(defvar my/org-calendar-repeat--events)

(defconst my/org-calendar-view-buffer "*Org Week (read only)*")
;; Doom's generic star-buffer rule otherwise opens this calendar in a drawer.
(when (fboundp 'set-popup-rule!)
  (set-popup-rule! "\\`\\*Org Week (read only)\\*\\'" :ignore t))
(defvar-local my/org-calendar-view-profile nil
  "Visible profile: nil for both, or work/personal as a string.")

(defun my/org-calendar-view--color (headline)
  "Colour HEADLINE by its existing Work/Personal category, without adding tags."
  (save-excursion
    (goto-char (org-element-property :begin headline))
    (face-foreground (if (equal (org-get-category) "Work")
                         'font-lock-keyword-face 'font-lock-string-face) nil t)))

(defun my/org-calendar-view--source (marker &optional occurrence)
  "Keep a live heading MARKER without exposing the Org backend's edit marker."
  (org-with-point-at marker
    (org-back-to-heading t)
    (list :heading-marker (point-marker) :occurrence occurrence)))

(defun my/org-calendar-view--org-events (start end)
  "Read only scheduled tasks and event timestamps intersecting START and END."
  (let ((org-timegrid-org-files (mapcar #'my/org-file
                                      '("work.org" "personal.org"
                                        "calendar-work.org" "calendar-personal.org")))
        (org-timegrid-org-capture-file nil)
        (org-timegrid-org-auto-save nil)
        (org-timegrid-org-repeater-history nil)
        (org-timegrid-org-show-done nil)
        (org-timegrid-org-exclude-properties '(("GCAL_AUTO_RECURRING" . nil)))
        (org-timegrid-org-color-function #'my/org-calendar-view--color)
        result)
    (dolist (event (org-timegrid-org--list-events start end))
      (let* ((source (org-timegrid-event-source event))
             (marker (plist-get source :marker))
             (calendar-file (member (expand-file-name (plist-get source :file))
                                    (mapcar #'my/org-file '("calendar-work.org" "calendar-personal.org"))))
             (state (org-with-point-at marker (org-get-todo-state))))
        (when (if calendar-file
                  (and (null state) (eq (plist-get source :kind) 'timestamp))
                (and (member state '("TODO" "DOING" "WAIT"))
                     (eq (plist-get source :kind) 'scheduled)))
          (unless calendar-file
            (setf (org-timegrid-event-title event)
                  (format "%s %s" state (org-timegrid-event-title event))))
          (setf (org-timegrid-event-source event) (my/org-calendar-view--source marker))
          (push event result))))
    (nreverse result)))

(defun my/org-calendar-view--deadlines (start end)
  "Show deadlines as labelled date-rail markers, never as reserved work time."
  (let (events)
    (dolist (file (mapcar #'my/org-file '("work.org" "personal.org")))
      (when (file-readable-p file)
        (with-current-buffer (find-file-noselect file)
          (org-with-wide-buffer
           (save-excursion
             (org-element-map (org-element-parse-buffer) 'headline
               (lambda (headline)
                 (when-let* ((timestamp (org-element-property :deadline headline)))
                   (when (member (org-element-property :todo-keyword headline) '("TODO" "DOING" "WAIT"))
                     (let* ((day (org-timegrid-org--timestamp-all-day-minutes timestamp nil))
                            (hour (org-element-property :hour-start timestamp))
                            (minute (org-element-property :minute-start timestamp)))
                       (when (and (< day end) (> (+ day 1440) start))
                         (goto-char (org-element-property :begin headline))
                         (push (org-timegrid-event-create
                                :id (list file (point) 'deadline)
                                :title (format "Due%s: %s"
                                               (if hour (format " %02d:%02d" hour minute) "")
                                               (org-element-property :raw-value headline))
                                :start day :end (+ day 1440) :all-day t
                                :color (face-foreground 'font-lock-warning-face nil t)
                                :source (my/org-calendar-view--source (point-marker)))
                               events))))))))))))
    (nreverse events)))

(defun my/org-calendar-view--google-minute (object)
  "Convert Google's OBJECT to local civil minutes, preserving all-day dates."
  (let* ((date (plist-get object :date))
         (time (and (not date) (parse-iso8601-time-string (plist-get object :dateTime))))
         (parts (mapcar #'string-to-number
                        (split-string (or date (format-time-string "%F" time)) "-")))
         (day (calendar-absolute-from-gregorian (list (nth 1 parts) (nth 2 parts) (car parts)))))
    (+ (* day 1440) (if date 0
                     (+ (* 60 (string-to-number (format-time-string "%H" time)))
                        (string-to-number (format-time-string "%M" time)))))))

(defun my/org-calendar-view--occurrences (start end)
  "Read Google's effective occurrence cache, including pending scoped changes."
  (let (events)
    (when (and (fboundp 'my/org-calendar-repeat--effective-events)
               (equal my/org-calendar-auto--calendar my/org-calendar-id)
               (my/org-calendar-auto--same-file-p (my/org-file "calendar-personal.org")))
      (my/org-calendar-repeat--ensure-state)
      (dolist (event (my/org-calendar-repeat--effective-events))
        (unless (equal (plist-get event :status) "cancelled")
          (when-let* ((marker (my/org-calendar-repeat--series-marker (plist-get event :recurringEventId))))
            (unless (org-with-point-at marker (equal (org-get-todo-state) "CANCELLED"))
              (let ((from (my/org-calendar-view--google-minute (plist-get event :start)))
                    (to (my/org-calendar-view--google-minute (plist-get event :end))))
                (when (and (< from end) (> to start))
                  (push (org-timegrid-event-create
                         :id (list 'google (plist-get event :id))
                         :title (or (plist-get event :summary) "busy") :start from :end to
                         :all-day (and (plist-get (plist-get event :start) :date) t)
                         :color (face-foreground 'font-lock-string-face nil t)
                         :source (my/org-calendar-view--source marker (plist-get event :id)))
                        events))))))))
    (nreverse events)))

(defun my/org-calendar-view--list (start end)
  "List the central files and cached occurrences without network calls or saves."
  (let ((events (append (my/org-calendar-view--org-events start end)
                        (my/org-calendar-view--deadlines start end)
                        (my/org-calendar-view--occurrences start end))))
    (if (null my/org-calendar-view-profile) events
      (let ((files (mapcar #'my/org-file
                          (if (equal my/org-calendar-view-profile "work")
                              '("work.org" "calendar-work.org")
                            '("personal.org" "calendar-personal.org")))))
        (cl-remove-if-not
         (lambda (event)
           (let ((marker (plist-get (org-timegrid-event-source event) :heading-marker)))
             (member (buffer-file-name (marker-buffer marker)) files)))
         events)))))

(defun my/org-calendar-view-filter ()
  "Choose Work, Personal, or both, without changing source files."
  (interactive)
  (setq my/org-calendar-view-profile
        (pcase (completing-read "Week profile: " '("Both" "Work" "Personal") nil t)
          ("Work" "work") ("Personal" "personal") (_ nil)))
  (setq mode-name (format "Week (%s, read only)"
                          (or my/org-calendar-view-profile "both")))
  (org-timegrid--refresh-data))

(defun my/org-calendar-view--visit (event)
  "Visit EVENT's source; scoped Google edits remain in the normal agenda."
  (let* ((source (org-timegrid-event-source event))
         (marker (plist-get source :heading-marker)))
    (unless (and (markerp marker) (marker-buffer marker))
      (user-error "The source is no longer open; refresh the week view"))
    (pop-to-buffer (marker-buffer marker))
    (goto-char marker)
    (org-fold-show-context)
    (when (plist-get source :occurrence)
      (message "This is the shared series heading; use agenda , e for an occurrence edit"))))

(defvar my/org-calendar-view--backend
  (org-timegrid-backend-create :name "Read-only Org week"
                              :list-function #'my/org-calendar-view--list
                              :visit-function #'my/org-calendar-view--visit)
  "No create, update, delete, undo, or other mutation callbacks.")

(defun my/org-calendar-view-read-only ()
  "Explain where edits belong instead of offering unsafe graphical mutations."
  (interactive)
  (user-error "Read-only week: use Today/Review or visit the source with RET to edit"))

(defun my/org-calendar-view-refresh-visible (&rest _)
  "Refresh a visible SVG view after sync, without triggering another sync."
  (when-let* ((buffer (get-buffer my/org-calendar-view-buffer))
               ((get-buffer-window buffer t)))
    ;; A display failure must not turn a successful sync into an error.
    (condition-case err
        (with-current-buffer buffer (org-timegrid--refresh-data))
      (error (message "Week view could not refresh: %s" (error-message-string err))))))

;;;###autoload
(defun my/org-calendar-week ()
  "Open a read-only graphical week using central files and cached Google dates."
  (interactive)
  (unless (and (display-graphic-p) (image-type-available-p 'svg))
    (user-error "The graphical week needs SVG support; use Today or Review here"))
  (let ((org-timegrid-buffer-name my/org-calendar-view-buffer)
        (display-buffer-overriding-action
         '((display-buffer-same-window) (inhibit-same-window . nil))))
    (org-timegrid-open my/org-calendar-view--backend))
  (setq-local mode-name (format "Week (%s, read only)"
                              (or my/org-calendar-view-profile "both")))
  (use-local-map (copy-keymap org-timegrid-mode-map))
  ;; Nil mutation callbacks stop mouse/keyboard edits. Block the source-command
  ;; shortcuts too; custom sources intentionally expose no editable :marker.
  (dolist (key '("d" "e" "t" "DEL" "<delete>" "<backspace>" "C-w" "C-y" "M-y"
                 ":" "C-c C-q" "C-c C-t" "," "C-c ," "i" "O" "z" "C-c C-z"
                 "C-c C-x e" "C-c C-w" "$"))
    (keymap-set (current-local-map) key #'my/org-calendar-view-read-only))
  (keymap-set (current-local-map) "[" #'org-timegrid-previous-week)
  (keymap-set (current-local-map) "]" #'org-timegrid-next-week)
  (keymap-set (current-local-map) "F" #'my/org-calendar-view-filter)
  (when (fboundp 'evil-emacs-state) (evil-emacs-state))
  (when (fboundp 'my/org-calendar-auto--finish)
    (advice-add 'my/org-calendar-auto--finish :after #'my/org-calendar-view-refresh-visible))
  (message "Read-only week: RET visits source; [ / ] change week; F filters; g shows today; q closes"))

(provide 'org-calendar-view)
