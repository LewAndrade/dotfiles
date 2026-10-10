;;; org-calendar-auto.el --- Saved personal events sync automatically -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'org)
(require 'org-agenda)
(require 'org-element)
(require 'json)
(require 'button)
(require 'request)
(require 'iso8601)
(require 'parse-time)

(declare-function org-gcal--event-id-from-entry-id "org-gcal" (entry-id))
(declare-function org-gcal--format-entry-id "org-gcal" (calendar-id event-id))
(declare-function parse-iso8601-time-string "parse-time" (date))

(defgroup my/org-calendar-auto nil
  "Automatic personal calendar synchronization."
  :group 'org)

(defvar my/org-calendar-auto-mode nil)
(defvar my/org-calendar-auto-status "needs login")
(defvar my/org-calendar-auto--file nil)
(defvar my/org-calendar-auto--calendar nil)
(defvar my/org-calendar-auto--timer nil)
(defvar my/org-calendar-auto--debounce nil)
(defvar my/org-calendar-auto--busy nil)
(defvar my/org-calendar-auto--rerun nil)
(defvar my/org-calendar-auto--response nil)
(defvar my/org-calendar-auto--generation 0)
(defvar my/org-calendar-auto--saving nil)
(defvar my/org-calendar-auto--refreshing nil)
(defvar my/org-calendar-auto--last-run 0)
(defvar my/org-calendar-auto--attention nil)
(defvar my/org-calendar-auto--last-error nil)
(defvar my/org-calendar-auto--remote-table nil)
(defvar my/org-calendar-auto--local-table nil)

(defun my/org-calendar-auto--status (status)
  "Set the quiet modeline STATUS, without repeated notifications."
  (let ((previous my/org-calendar-auto-status))
    (setq my/org-calendar-auto-status status)
    (when (and (equal status "needs attention") (not (equal previous status)))
      (message "Personal calendar needs attention; SPC n g s shows details")))
  (force-mode-line-update t))

(defun my/org-calendar-auto--same-file-p (file)
  "Accept the exact configured path or a verified filesystem alias of FILE."
  (and my/org-calendar-auto--file file
       ;; Avoid intermittent filesystem identity failures for two identical paths.
       ;; Still use physical identity when the path is an alias, never just its basename.
       (or (equal (expand-file-name file) (expand-file-name my/org-calendar-auto--file))
           (file-equal-p file my/org-calendar-auto--file))))

(defun my/org-calendar-auto--file-p ()
  "Return non-nil only in the configured personal calendar buffer."
  (my/org-calendar-auto--same-file-p buffer-file-name))

(defun my/org-calendar-auto--buffer ()
  "Return the personal calendar buffer, checking the pinned test mapping."
  (unless (and (equal my/org-calendar-auto--calendar my/org-gcal-test-calendar-id)
               (string-suffix-p "@group.calendar.google.com" my/org-calendar-auto--calendar))
    (user-error "Calendar mapping changed; disable automation and review it first"))
  (find-file-noselect my/org-calendar-auto--file))

(defun my/org-calendar-auto--save ()
  "Save sync metadata without triggering another after-save cycle."
  (let ((my/org-calendar-auto--saving t)) (save-buffer)))

(defun my/org-calendar-auto--day (year month day &optional increment)
  "Format a civil date, adding INCREMENT calendar days without DST drift."
  (let ((date (calendar-gregorian-from-absolute
               (+ (calendar-absolute-from-gregorian (list month day year)) (or increment 0)))))
    (format "%04d-%02d-%02d" (nth 2 date) (car date) (nth 1 date))))

(defun my/org-calendar-auto--instant (time)
  "Normalize an RFC3339 TIME to the minute precision Org can represent."
  (format-time-string "%FT%TZ"
                      (seconds-to-time (* 60 (floor (/ (float-time (parse-iso8601-time-string time)) 60)))) t))

(defun my/org-calendar-auto--time-object (time)
  "Normalize Google's TIME object to a stable JSON alist."
  (if-let* ((date (plist-get time :date)))
      `((date . ,date))
    `((dateTime . ,(my/org-calendar-auto--instant (plist-get time :dateTime))))))

(defun my/org-calendar-auto--remote-payload (event)
  "Return only the event fields managed by this workflow from EVENT."
  (unless (equal (plist-get event :status) "cancelled")
    `((summary . ,(replace-regexp-in-string "[\r\n]+" " " (or (plist-get event :summary) "busy")))
      (start . ,(append (my/org-calendar-auto--time-object (plist-get event :start))
                       (when (plist-get event :recurrence)
                         (when-let* ((zone (plist-get (plist-get event :start) :timeZone)))
                           (list (cons 'timeZone zone))))))
      (end . ,(append (my/org-calendar-auto--time-object (plist-get event :end))
                     (when (plist-get event :recurrence)
                       (when-let* ((zone (plist-get (plist-get event :end) :timeZone)))
                         (list (cons 'timeZone zone))))))
      (description . ,(string-trim (or (plist-get event :description) "")))
      (location . ,(or (plist-get event :location) ""))
      (transparency . ,(or (plist-get event :transparency) "opaque"))
      (status . "confirmed")
      ,@(when (plist-get event :recurrence)
          `((recurrence . ,(vconcat (plist-get event :recurrence))))))))

(defun my/org-calendar-auto--hash (payload)
  "Return a stable digest of managed event PAYLOAD."
  (secure-hash 'sha256 (encode-coding-string (json-encode payload) 'utf-8)))

(defun my/org-calendar-auto--drawer ()
  "Return (BEGIN END CONTENT) for the current heading's event drawer."
  (save-excursion
    (org-back-to-heading t)
    (let ((limit (save-excursion (outline-next-heading) (point))))
      (when (re-search-forward "^[ \t]*:org-gcal:[ \t]*$" limit t)
        (let ((begin (line-beginning-position))
              (content-start (progn (forward-line) (point))))
          (unless (re-search-forward "^[ \t]*:END:[ \t]*$" limit t)
            (user-error "Event drawer has no :END:"))
          (list begin (min (point-max) (1+ (line-end-position)))
                (buffer-substring-no-properties content-start (line-beginning-position))))))))

(defun my/org-calendar-auto--local-payload ()
  "Parse a complete event at point, without prompts or default durations."
  (let* ((state (org-get-todo-state))
         (drawer (my/org-calendar-auto--drawer))
         (title (org-get-heading t t t t))
         timestamp description)
    (unless (or (null state) (equal state "CANCELLED"))
      (user-error "Calendar headings must be events, not tasks"))
    (unless (and drawer (not (string-empty-p title)))
      (user-error "Event needs a title and an org-gcal timestamp drawer"))
    (when (or (org-entry-get nil "SCHEDULED") (org-entry-get nil "DEADLINE"))
      (user-error "Put event times in the org-gcal drawer, not SCHEDULED or DEADLINE"))
    (when (and (org-entry-get nil "recurrence") (not (org-entry-get nil "GCAL_AUTO_RECURRING")))
      (user-error "Edit recurring series in Google; individual occurrences are supported"))
    (save-excursion
      (goto-char (nth 0 drawer))
      (unless (re-search-forward "<[^>]+>" (nth 1 drawer) t)
        (user-error "Event needs an active timestamp"))
      (goto-char (match-beginning 0))
      (setq timestamp (org-element-timestamp-parser))
      (when (org-element-property :repeater-type timestamp)
        (user-error "Create recurring series in Google before editing individual occurrences"))
      (forward-line)
      (setq description (string-trim
                         (replace-regexp-in-string
                          "^," "" (buffer-substring-no-properties
                                    (point) (save-excursion
                                              (goto-char (nth 1 drawer))
                                              (re-search-backward "^[ \t]*:END:") (point)))))))
    (let* ((year (org-element-property :year-start timestamp))
           (month (org-element-property :month-start timestamp))
           (day (org-element-property :day-start timestamp))
           (hour (org-element-property :hour-start timestamp))
           (start (if hour
                      `((dateTime . ,(format-time-string
                                      "%FT%TZ" (encode-time 0 (org-element-property :minute-start timestamp)
                                                            hour day month year) t)))
                    `((date . ,(my/org-calendar-auto--day year month day)))))
           (end (if hour
                    `((dateTime . ,(format-time-string
                                    "%FT%TZ" (encode-time 0 (org-element-property :minute-end timestamp)
                                                          (org-element-property :hour-end timestamp)
                                                          (org-element-property :day-end timestamp)
                                                          (org-element-property :month-end timestamp)
                                                          (org-element-property :year-end timestamp)) t)))
                  `((date . ,(my/org-calendar-auto--day
                              (org-element-property :year-end timestamp)
                              (org-element-property :month-end timestamp)
                              (org-element-property :day-end timestamp) 1))))))
      (unless (string< (cdar start) (cdar end))
        (user-error "Event end must be after its start"))
      (when-let* ((zone (org-entry-get nil "GCAL_TIMEZONE")))
        (setq start (append start (list (cons 'timeZone zone)))))
      (when-let* ((zone (org-entry-get nil "GCAL_END_TIMEZONE")))
        (setq end (append end (list (cons 'timeZone zone)))))
      `((summary . ,title) (start . ,start) (end . ,end)
        (description . ,description) (location . ,(or (org-entry-get nil "LOCATION") ""))
        (transparency . ,(or (org-entry-get nil "TRANSPARENCY") "opaque"))
        (status . ,(if state "cancelled" "confirmed"))
        ,@(when (org-entry-get nil "GCAL_AUTO_RECURRING")
            `((recurrence . ,(vconcat (json-parse-string (org-entry-get nil "recurrence")
                                                        :array-type 'list)))))))))

(defun my/org-calendar-auto--record ()
  "Read sync identity and managed fields from the heading at point."
  (let ((calendar (org-entry-get nil "calendar-id")))
    (when (and calendar (not (equal calendar my/org-calendar-auto--calendar)))
      (user-error "Event is linked to another calendar")))
  (unless (and (equal (org-get-todo-state) "CANCELLED")
               (not (or (org-entry-get nil "entry-id") (org-entry-get nil "GCAL_AUTO_ID"))))
  (let* ((payload (my/org-calendar-auto--local-payload))
         (linked (org-entry-get nil "entry-id"))
         (id (or (and linked (org-gcal--event-id-from-entry-id linked))
                 (org-entry-get nil "GCAL_AUTO_ID"))))
    (unless (or id (equal (alist-get 'status payload) "cancelled"))
      ;; Google accepts hexadecimal IDs. Persist before POST to survive lost replies.
      (setq id (secure-hash 'sha256 (concat (org-id-new) my/org-calendar-auto--calendar)))
      (org-entry-put nil "GCAL_AUTO_ID" id))
    (when id
      (list :id id :marker (point-marker) :payload payload
            :hash (my/org-calendar-auto--hash payload) :linked linked
            :base (org-entry-get nil "GCAL_AUTO_BASE")
            :etag (org-entry-get nil "ETag")
            :conflict (org-entry-get nil "GCAL_AUTO_CONFLICT")
            :resolution (org-entry-get nil "GCAL_AUTO_RESOLUTION")
            :resolution-hash (org-entry-get nil "GCAL_AUTO_RESOLUTION_HASH"))))))

(defun my/org-calendar-auto--decode (text)
  (json-parse-string (decode-coding-string (base64-decode-string text) 'utf-8)
                     :object-type 'plist :array-type 'list :null-object nil))

(defun my/org-calendar-auto--encode (object)
  (base64-encode-string (encode-coding-string (json-encode object) 'utf-8) t))

(defun my/org-calendar-auto--plan (local remote)
  "Decide how to reconcile LOCAL and REMOTE, without changing either."
  (let* ((cancelled (equal (alist-get 'status (plist-get local :payload)) "cancelled"))
         (remote-cancelled (or (null remote) (equal (plist-get remote :status) "cancelled")))
         (base (plist-get local :base))
         (hash (plist-get local :hash))
         (remote-hash (unless remote-cancelled
                        (my/org-calendar-auto--hash (my/org-calendar-auto--remote-payload remote))))
         (same-etag (equal (plist-get local :etag) (plist-get remote :etag)))
         (conflict (plist-get local :conflict))
         (resolution (plist-get local :resolution)))
    (cond
     ((and conflict resolution)
      (if (and (equal hash (plist-get local :resolution-hash))
               (equal (plist-get (my/org-calendar-auto--decode conflict) :etag)
                      (plist-get remote :etag)))
          (cond
           ((equal resolution "google") 'pull)
           ((equal resolution "restore")
            (if (and remote-cancelled (not cancelled)) 'restore 'conflict))
           (t (if cancelled 'delete (if remote-cancelled 'conflict 'push))))
        'conflict))
     (conflict (if (or (equal hash remote-hash) (and cancelled remote-cancelled)) 'ack 'conflict))
     ((and remote-cancelled cancelled) 'ack)
     ((null remote)
      (if (or base (plist-get local :linked))
          (if (and base (not (equal base hash))) 'conflict 'pull)
        'create))
     (remote-cancelled (if (and base (not (equal base hash))) 'conflict 'pull))
     ((equal hash remote-hash) 'ack)
     ((and base (equal hash base)) 'pull)
     ((or (and (plist-get local :etag) same-etag) (equal base remote-hash))
      (if cancelled 'delete 'push))
     (t 'conflict))))

(defun my/org-calendar-auto--timestamp (event)
  "Render EVENT in local time, respecting exclusive all-day ends."
  (let* ((start (plist-get event :start)) (end (plist-get event :end))
         (date (plist-get start :date)))
    (if date
        (let* ((last-date (plist-get end :date))
               (parts (mapcar #'string-to-number (split-string last-date "-")))
               (last (my/org-calendar-auto--day (nth 0 parts) (nth 1 parts) (nth 2 parts) -1)))
          (if (equal date last) (format "<%s>" date)
            (format "<%s>--<%s>" date last)))
      (format "%s--%s"
              (format-time-string "<%Y-%m-%d %a %H:%M>" (parse-iso8601-time-string (plist-get start :dateTime)))
              (format-time-string "<%Y-%m-%d %a %H:%M>" (parse-iso8601-time-string (plist-get end :dateTime)))))))

(defun my/org-calendar-auto--metadata (id event)
  "Record confirmed identity and baseline for ID and EVENT at point."
  (org-entry-put nil "calendar-id" my/org-calendar-auto--calendar)
  (org-entry-put nil "entry-id" (org-gcal--format-entry-id my/org-calendar-auto--calendar id))
  (org-entry-put nil "GCAL_AUTO_ID" id)
  (when-let* ((etag (plist-get event :etag))) (org-entry-put nil "ETag" etag))
  (org-entry-put nil "GCAL_AUTO_BASE" (my/org-calendar-auto--hash (my/org-calendar-auto--local-payload)))
  (dolist (property '("GCAL_AUTO_CONFLICT" "GCAL_AUTO_RESOLUTION" "GCAL_AUTO_RESOLUTION_HASH"
                      "GCAL_SERIES_APPROVED" "GCAL_AUTO_ERROR"))
    (org-entry-delete nil property)))

(defun my/org-calendar-auto--import (id event)
  "Update managed fields only, keeping the local heading and unrelated notes."
  (if (or (null event) (equal (plist-get event :status) "cancelled"))
      (let ((org-inhibit-logging t)) (org-todo "CANCELLED"))
    (org-edit-headline (replace-regexp-in-string "[\r\n]+" " " (or (plist-get event :summary) "busy")))
    (when (equal (org-get-todo-state) "CANCELLED")
      ;; Logging is inhibited below, so Org would otherwise skip CLOSED cleanup too.
      ;; Remove only the planning stamp, not historical logbook entries or private notes.
      (save-excursion (org-add-planning-info nil nil 'closed)))
    (when (org-get-todo-state) (let ((org-inhibit-logging t)) (org-todo 'none)))
    (dolist (pair '(("LOCATION" . :location) ("TRANSPARENCY" . :transparency)))
      (if-let* ((value (plist-get event (cdr pair))))
          (org-entry-put nil (car pair) value)
        (org-entry-delete nil (car pair))))
    (when-let* ((series (plist-get event :recurringEventId)))
      (org-entry-put nil "GCAL_AUTO_SERIES" series))
    (unless (plist-get event :recurrence)
      (dolist (property '("GCAL_AUTO_RECURRING" "recurrence" "GCAL_TIMEZONE" "GCAL_END_TIMEZONE"))
        (org-entry-delete nil property)))
    (when (plist-get event :recurrence)
      (org-entry-put nil "GCAL_AUTO_RECURRING" "t")
      (org-entry-put nil "recurrence" (json-encode (vconcat (plist-get event :recurrence))))
      (dolist (pair '(("GCAL_TIMEZONE" . :start) ("GCAL_END_TIMEZONE" . :end)))
        (if-let* ((zone (plist-get (plist-get event (cdr pair)) :timeZone)))
            (org-entry-put nil (car pair) zone)
          (org-entry-delete nil (car pair)))))
    (let* ((drawer (my/org-calendar-auto--drawer))
           (description (replace-regexp-in-string
                         "^\\([,*]\\|:END:\\)" ",\\1" (string-trim (or (plist-get event :description) ""))))
           (text (concat ":org-gcal:\n" (my/org-calendar-auto--timestamp event) "\n"
                         (unless (string-empty-p description) (concat "\n" description "\n")) ":END:\n")))
      (if drawer
          (progn (goto-char (car drawer)) (delete-region (nth 0 drawer) (nth 1 drawer)))
        (org-end-of-meta-data t))
      (insert text)
      (org-back-to-heading t)))
  (my/org-calendar-auto--metadata id event))

(defun my/org-calendar-auto--conflict (event)
  "Preserve Google's EVENT in the local heading without overwriting local fields."
  (org-entry-put nil "GCAL_AUTO_CONFLICT" (my/org-calendar-auto--encode event))
  (org-entry-delete nil "GCAL_AUTO_RESOLUTION")
  (org-entry-delete nil "GCAL_AUTO_RESOLUTION_HASH")
  (setq my/org-calendar-auto--attention t))

(defun my/org-calendar-auto--request (method id payload etag callback &optional params)
  "Make one asynchronous, bounded API request to the pinned personal calendar."
  (when my/org-calendar-auto-mode
  (let ((generation my/org-calendar-auto--generation))
    (setq my/org-calendar-auto--response
          (request
            (concat "https://www.googleapis.com/calendar/v3/calendars/"
                    (url-hexify-string my/org-calendar-auto--calendar) "/events"
                    (when id (concat "/" (url-hexify-string id))))
            :type method :timeout 20 :params params
            :headers (append `(("Authorization" . ,(concat "Bearer " my/org-calendar-access-token))
                               ("Content-Type" . "application/json; charset=utf-8"))
                             (when etag (list (cons "If-Match" etag))))
            :data (when payload (encode-coding-string (json-encode payload) 'utf-8))
            :parser (lambda () (json-parse-buffer :object-type 'plist :array-type 'list :null-object nil))
            :complete (cl-function
                       (lambda (&key response data &allow-other-keys)
                         (when (and my/org-calendar-auto-mode (= generation my/org-calendar-auto--generation))
                           (when (plist-get data :error)
                             (setq my/org-calendar-auto--last-error
                                   (or (plist-get (plist-get data :error) :message) "Calendar API error")))
                           (condition-case nil
                               (funcall callback (request-response-status-code response) data)
                             (error (my/org-calendar-auto--finish "needs attention")))))))))))

(defun my/org-calendar-auto--failure (status)
  "End a failed cycle without losing queued local changes."
  (when (eq status 401)
    (setq my/org-calendar-access-token nil my/org-calendar-token-expiration nil))
  (my/org-calendar-auto--finish (if (memq status '(400 403)) "needs attention" "pending"))
  (when (and (eq status 401) (fboundp 'my/org-calendar-background-refresh))
    (my/org-calendar-background-refresh)))

(defun my/org-calendar-auto--safe-marker (marker)
  "Return non-nil if MARKER still identifies an editable saved personal heading."
  (and (marker-buffer marker)
       (with-current-buffer (marker-buffer marker)
         (and (my/org-calendar-auto--file-p) (not (buffer-modified-p))
              (save-excursion (goto-char marker) (org-at-heading-p))))))

(defun my/org-calendar-auto--write (local remote action next)
  "Create, patch, or cancel LOCAL, conditional on REMOTE's version, then NEXT."
  (let* ((id (plist-get local :id)) (marker (plist-get local :marker))
         (payload (copy-tree (plist-get local :payload)))
         (method (pcase action ('create "POST") ('delete "DELETE") (_ "PATCH"))))
    (when (eq action 'create)
      (setq payload (append payload `((id . ,id) (extendedProperties . ((private . ((orgAutoId . ,id)))))))))
    (my/org-calendar-auto--request
     method (unless (eq action 'create) id) (unless (eq action 'delete) payload)
     (unless (eq action 'create) (plist-get remote :etag))
     (lambda (status data)
       (cond
        ((or (and status (<= 200 status) (< status 300))
             (and (eq action 'delete) (memq status '(404 410))))
         (unless (my/org-calendar-auto--safe-marker marker)
           (setq my/org-calendar-auto--rerun t))
         (when (my/org-calendar-auto--safe-marker marker)
           (org-with-point-at marker
             ;; Never acknowledge newer edits as if they were sent in this request.
             (let ((current (my/org-calendar-auto--record)))
               (when (equal (plist-get current :id) id)
                 (org-entry-put nil "calendar-id" my/org-calendar-auto--calendar)
                 (org-entry-put nil "entry-id" (org-gcal--format-entry-id my/org-calendar-auto--calendar id))
                 (when-let* ((etag (plist-get data :etag))) (org-entry-put nil "ETag" etag))
                 (org-entry-put nil "GCAL_AUTO_BASE" (plist-get local :hash))
                 (unless (equal (plist-get current :hash) (plist-get local :hash))
                   (setq my/org-calendar-auto--rerun t))
                 (when (equal (plist-get current :hash) (plist-get local :hash))
                    (dolist (property '("GCAL_AUTO_CONFLICT" "GCAL_AUTO_RESOLUTION" "GCAL_AUTO_RESOLUTION_HASH"
                                        "GCAL_SERIES_APPROVED" "GCAL_AUTO_ERROR"))
                     (org-entry-delete nil property)))
                 (my/org-calendar-auto--save)))))
         (funcall next))
        ((memq status '(409 412))
         ;; A lost create reply or racing remote edit: read the latest version, never blind retry.
         (my/org-calendar-auto--request "GET" id nil nil
                                        (lambda (code latest)
                                          (if (eq code 200)
                                              (when (my/org-calendar-auto--safe-marker marker)
                                                (org-with-point-at marker
                                                  (my/org-calendar-auto--conflict latest)
                                                  (my/org-calendar-auto--save))
                                                (funcall next))
                                            (my/org-calendar-auto--failure code)))))
        (t (my/org-calendar-auto--failure status))))
     '((sendUpdates . "none")))))

(defun my/org-calendar-auto--restore (local remote next)
  "Recreate explicitly approved LOCAL under a fresh ID after verifying REMOTE.
Persist the new identity before POST, so retries cannot create extra copies.
Keep the old identity and conflict snapshot for local recovery history."
  (let ((marker (plist-get local :marker)))
    (if (not (my/org-calendar-auto--safe-marker marker))
        (progn (setq my/org-calendar-auto--rerun t) (funcall next))
      (org-with-point-at marker
        (let ((current (my/org-calendar-auto--record)))
          (if (not (and (equal (plist-get local :id) (plist-get current :id))
                        (equal (plist-get local :hash) (plist-get current :hash))
                        (equal (plist-get current :resolution) "restore")
                        (or (null remote) (equal (plist-get remote :status) "cancelled"))))
              (progn (setq my/org-calendar-auto--rerun t) (funcall next))
            (org-entry-put nil "GCAL_AUTO_PREVIOUS"
                           (my/org-calendar-auto--encode
                            `((org . ,(plist-get local :payload)) (google . ,remote)
                              (deleted-id . ,(plist-get local :id)))))
            (org-entry-put nil "GCAL_AUTO_RESTORED_FROM" (plist-get local :id))
            (dolist (property '("entry-id" "ETag" "GCAL_AUTO_BASE" "GCAL_AUTO_ID"
                                "GCAL_AUTO_CONFLICT" "GCAL_AUTO_RESOLUTION" "GCAL_AUTO_RESOLUTION_HASH"
                                "GCAL_SERIES_APPROVED" "GCAL_AUTO_ERROR"))
              (org-entry-delete nil property))
            ;; `--record' allocates the replacement ID, but keeps event content and notes intact.
            (let ((replacement (my/org-calendar-auto--record)))
              (when (org-entry-get nil "GCAL_AUTO_RECURRING")
                (org-entry-put nil "GCAL_SERIES_APPROVED" (plist-get replacement :hash)))
              (my/org-calendar-auto--save)
              (setq my/org-calendar-auto--rerun t)
              (my/org-calendar-auto--write replacement nil 'create next))))))))

(defun my/org-calendar-auto--reconcile (marker remote next)
  "Reconcile a saved heading at MARKER with REMOTE, then call NEXT."
  (if (not (my/org-calendar-auto--safe-marker marker))
      (progn (setq my/org-calendar-auto--rerun t) (funcall next))
    (org-with-point-at marker
      (condition-case nil
          (let* ((local (my/org-calendar-auto--record))
                 (id (plist-get local :id))
                 (action (my/org-calendar-auto--plan local remote)))
            (pcase action
              ((or 'ack 'pull)
               (when (plist-get local :resolution)
                 (org-entry-put nil "GCAL_AUTO_PREVIOUS"
                                (my/org-calendar-auto--encode
                                 `((org . ,(plist-get local :payload)) (google . ,remote)))))
               (unless (and (eq action 'ack)
                            (equal (plist-get local :base) (plist-get local :hash))
                            (equal (plist-get local :etag) (plist-get remote :etag))
                            (not (plist-get local :conflict)))
                 (if (eq action 'pull) (my/org-calendar-auto--import id remote)
                   (my/org-calendar-auto--metadata id remote))
                 (my/org-calendar-auto--save))
               (funcall next))
               ('conflict
               (my/org-calendar-auto--conflict remote)
               (my/org-calendar-auto--save)
                (funcall next))
               ('restore (my/org-calendar-auto--restore local remote next))
              (_
               (if (and (org-entry-get nil "GCAL_AUTO_RECURRING")
                        (not (equal (org-entry-get nil "GCAL_SERIES_APPROVED") (plist-get local :hash))))
                   (progn
                     (org-entry-put nil "GCAL_AUTO_ERROR" "Series changes need approval in SPC n g s")
                     (my/org-calendar-auto--save)
                     (setq my/org-calendar-auto--attention t)
                     (funcall next))
                 (when (plist-get local :resolution)
                   (org-entry-put nil "GCAL_AUTO_PREVIOUS"
                                  (my/org-calendar-auto--encode
                                   `((org . ,(plist-get local :payload)) (google . ,remote))))
                   (my/org-calendar-auto--save))
                 (my/org-calendar-auto--write local remote action next)))))
        (error (setq my/org-calendar-auto--attention t) (funcall next))))))

(defun my/org-calendar-auto--process-local (records)
  "Process RECORDS one at a time, checking linked events outside the window."
  (if (null records)
      (my/org-calendar-auto--finish (if my/org-calendar-auto--attention "needs attention" "up to date"))
    (let* ((local (car records)) (id (plist-get local :id))
           (remote (gethash id my/org-calendar-auto--remote-table))
           (generation my/org-calendar-auto--generation)
           (next (lambda ()
                   ;; Yield between entries: a large calendar must not exhaust Lisp's stack.
                   (run-at-time
                    0 nil (lambda ()
                            (when (and my/org-calendar-auto-mode (= generation my/org-calendar-auto--generation))
                              (my/org-calendar-auto--process-local (cdr records))))))))
      (if remote
          (my/org-calendar-auto--reconcile (plist-get local :marker) remote next)
        (my/org-calendar-auto--request
         "GET" id nil nil
         (lambda (status data)
           (cond ((eq status 200) (my/org-calendar-auto--reconcile (plist-get local :marker) data next))
                 ((memq status '(404 410)) (my/org-calendar-auto--reconcile (plist-get local :marker) nil next))
                 (t (my/org-calendar-auto--failure status)))))))))

(defun my/org-calendar-auto--apply-remote (records)
  "Import fetched events, then reconcile pending occurrence and local RECORDS."
  (let ((buffer (my/org-calendar-auto--buffer)))
    (if (buffer-modified-p buffer)
        (my/org-calendar-auto--finish "pending")
      (with-current-buffer buffer
        (save-excursion
          (maphash
           (lambda (id event)
             (unless (or (gethash id my/org-calendar-auto--local-table)
                         (equal (plist-get event :status) "cancelled"))
               (goto-char (point-max))
               (unless (bolp) (insert "\n"))
               (insert "\n* Imported event\n")
               (forward-line -1)
               (my/org-calendar-auto--import id event)))
           my/org-calendar-auto--remote-table)
          (when (buffer-modified-p) (my/org-calendar-auto--save))))
      (my/org-calendar-repeat-process-pending
       (lambda () (my/org-calendar-auto--process-local records))))))

(defun my/org-calendar-auto--list (records &optional page)
  "Collect all remote pages before reconciling saved local RECORDS."
  (my/org-calendar-auto--request
   "GET" nil nil nil
   (lambda (status data)
     (if (not (eq status 200)) (my/org-calendar-auto--failure status)
       (dolist (event (plist-get data :items))
         (puthash (plist-get event :id) event my/org-calendar-auto--remote-table))
       (if-let* ((next-page (plist-get data :nextPageToken)))
           (my/org-calendar-auto--list records next-page)
          (my/org-calendar-repeat-prepare records #'my/org-calendar-auto--apply-remote))))
   (append `((singleEvents . "true") (showDeleted . "true") (maxResults . "250")
             (timeMin . ,(format-time-string "%FT%TZ" (time-subtract (current-time) (days-to-time 90)) t))
             (timeMax . ,(format-time-string "%FT%TZ" (time-add (current-time) (days-to-time 365)) t)))
           (when page (list (cons 'pageToken page))))))

(defun my/org-calendar-auto--start ()
  "Start a single sync cycle, only with saved buffers and an unlocked session."
  (when my/org-calendar-auto-mode
    (cond
     (my/org-calendar-auto--busy (setq my/org-calendar-auto--rerun t))
     ((not (my/org-calendar-session-ready-p))
      (my/org-calendar-auto--status
       (if (and (my/org-calendar-unlock-available-p)
                (not (memq my/org-calendar-auth-problem '(authorization unlock))))
           "pending" "needs login"))
      (when (fboundp 'my/org-calendar-background-refresh) (my/org-calendar-background-refresh)))
     ((bound-and-true-p org-gcal--sync-lock)
      (my/org-calendar-auto--status "pending"))
     (t
      (condition-case nil
          (let ((buffer (my/org-calendar-auto--buffer)) records)
            (if (buffer-modified-p buffer)
                (my/org-calendar-auto--status "pending")
              (setq my/org-calendar-auto--attention nil my/org-calendar-auto--last-error nil
                    my/org-calendar-auto--local-table (make-hash-table :test 'equal)
                    my/org-calendar-auto--remote-table (make-hash-table :test 'equal))
              (with-current-buffer buffer
                (org-with-wide-buffer
                 (org-map-entries
                  (lambda ()
                    (let* ((linked (org-entry-get nil "entry-id"))
                           (known-id (or (and linked (org-gcal--event-id-from-entry-id linked))
                                         (org-entry-get nil "GCAL_AUTO_ID"))))
                    (if (and known-id (gethash known-id my/org-calendar-auto--local-table))
                        (progn
                          (puthash known-id 'duplicate my/org-calendar-auto--local-table)
                          (setq my/org-calendar-auto--attention t
                                my/org-calendar-auto--last-error "Duplicate event identity: don't copy linked calendar headings"))
                    (when known-id (puthash known-id 'blocked my/org-calendar-auto--local-table))
                    (condition-case problem
                        (when-let* ((record (my/org-calendar-auto--record)))
                          (let ((id (plist-get record :id)))
                            (puthash id record my/org-calendar-auto--local-table)
                            (org-entry-delete nil "GCAL_AUTO_ERROR")
                            (push record records)))
                      (user-error
                       (org-entry-put nil "GCAL_AUTO_ERROR" (error-message-string problem))
                       (setq my/org-calendar-auto--attention t))
                      (error
                       (org-entry-put nil "GCAL_AUTO_ERROR" "Invalid event; check its title, timestamp and calendar identity")
                       (setq my/org-calendar-auto--attention t)))))) nil 'file))
                (when (buffer-modified-p) (my/org-calendar-auto--save)))
              (setq records (seq-filter
                             (lambda (record)
                               (listp (gethash (plist-get record :id) my/org-calendar-auto--local-table))) records))
              (setq my/org-calendar-auto--busy t my/org-calendar-auto--last-run (float-time))
              (my/org-calendar-auto--status "pending")
           (my/org-calendar-auto--list (nreverse records))))
        (error (my/org-calendar-auto--finish "needs attention")))))))

(defun my/org-calendar-auto--refresh-agendas ()
  "Refresh visible agendas without moving the selected source entry."
  (unless (or (active-minibuffer-window) (bound-and-true-p org-capture-mode))
    (let ((my/org-calendar-auto--refreshing t))
      (save-selected-window
        (dolist (window (window-list))
          (when (with-current-buffer (window-buffer window) (derived-mode-p 'org-agenda-mode))
            (with-selected-window window
              (let ((source (org-get-at-bol 'org-hd-marker))
                    (instance (org-get-at-bol 'my/org-calendar-repeat-id))
                    (old-point (point)) (start (window-start)))
                (org-agenda-redo t)
                (goto-char (min old-point (point-max)))
                (when source
                  (goto-char (point-min))
                  (while (and (< (point) (point-max))
                              (not (and (equal source (org-get-at-bol 'org-hd-marker))
                                        (or (null instance) (equal instance (org-get-at-bol 'my/org-calendar-repeat-id))))))
                    (forward-line))
                  (when (eobp) (goto-char (min old-point (point-max)))))
                (set-window-start window (min start (point-max)) t)))))))))

(defun my/org-calendar-auto--finish (status)
  "End a cycle with STATUS, refreshing the agenda only after confirmed work."
  (setq my/org-calendar-auto--busy nil my/org-calendar-auto--response nil)
  (my/org-calendar-auto--status (if (and my/org-calendar-auto--rerun (equal status "up to date")) "pending" status))
  (when (member status '("up to date" "needs attention"))
    (my/org-calendar-auto--refresh-agendas))
  (when my/org-calendar-auto--rerun
    (setq my/org-calendar-auto--rerun nil)
    (my/org-calendar-auto--schedule)))

(defun my/org-calendar-auto--schedule (&rest _)
  "Debounce saved personal-calendar edits for two seconds."
  (when (and my/org-calendar-auto-mode (not my/org-calendar-auto--saving)
             (not my/org-calendar-auto--refreshing))
    (when (timerp my/org-calendar-auto--debounce) (cancel-timer my/org-calendar-auto--debounce))
    (setq my/org-calendar-auto--debounce (run-at-time 2 nil #'my/org-calendar-auto--start))))

(defun my/org-calendar-auto--after-save ()
  (when (my/org-calendar-auto--file-p) (my/org-calendar-auto--schedule)))

(defun my/org-calendar-auto--agenda-open (&rest _)
  "Queue a Google check on user-driven agenda opens and redraws."
  (when (and my/org-calendar-auto-mode (derived-mode-p 'org-agenda-mode)
             (not my/org-calendar-auto--refreshing))
    (my/org-calendar-auto--schedule)))

(defun my/org-calendar-auto--agenda-todo (original &rest args)
  "Save an agenda cancellation, but never commit pre-existing unsaved edits."
  (let* ((marker (org-get-at-bol 'org-hd-marker))
         (clean (and marker (marker-buffer marker)
                     (with-current-buffer (marker-buffer marker)
                       (and (my/org-calendar-auto--file-p) (not (buffer-modified-p))))))
         (result (apply original args)))
    (when clean
      (org-with-point-at marker (when (buffer-modified-p) (save-buffer))))
    result))

(defun my/org-calendar-auto--resolve (marker choice)
  "Queue a resolution CHOICE for the conflict at MARKER."
  (unless (my/org-calendar-auto--safe-marker marker)
    (user-error "Save the calendar buffer before resolving this conflict"))
  (org-with-point-at marker
    (unless (org-entry-get nil "GCAL_AUTO_CONFLICT") (user-error "This event has no unresolved conflict"))
    (when (and (equal choice "org") (org-entry-get nil "GCAL_AUTO_RECURRING"))
      (unless (yes-or-no-p "Keep Org changes for the entire recurring series in Google? ")
        (user-error "Series changes not approved"))
      (org-entry-put nil "GCAL_SERIES_APPROVED"
                     (my/org-calendar-auto--hash (my/org-calendar-auto--local-payload))))
    (org-entry-put nil "GCAL_AUTO_RESOLUTION" choice)
    (org-entry-put nil "GCAL_AUTO_RESOLUTION_HASH"
                   (my/org-calendar-auto--hash (my/org-calendar-auto--local-payload)))
    (save-buffer))
  (my/org-calendar-auto--schedule)
  (message "Resolution queued; a newer Google change will require another review"))

(defun my/org-calendar-auto--queue-restore (marker expected-id expected-hash expected-conflict)
  "Confirm restoration of the exact deleted-event conflict the reader reviewed."
  (cl-labels ((check ()
                (unless (my/org-calendar-auto--safe-marker marker)
                  (user-error "Save the calendar before choosing restoration"))
                (org-with-point-at marker
                  (let ((current (my/org-calendar-auto--record)))
                    (unless (and (equal expected-id (plist-get current :id))
                                 (equal expected-hash (plist-get current :hash))
                                 (equal expected-conflict (plist-get current :conflict)))
                      (user-error "Event changed; reopen SPC n g s before choosing restoration"))
                    (when (or (equal (alist-get 'status (plist-get current :payload)) "cancelled")
                              (org-entry-get nil "GCAL_AUTO_SERIES"))
                      (user-error "Only active events or whole series can be recreated here"))
                    (let ((remote (my/org-calendar-auto--decode expected-conflict)))
                      (unless (or (null remote) (equal (plist-get remote :status) "cancelled"))
                        (user-error "Google has not deleted this event")))))))
    (check)
    (let ((series (org-with-point-at marker (org-entry-get nil "GCAL_AUTO_RECURRING"))))
      (unless (yes-or-no-p
               (if series
                   "Recreate this whole series from Org as NEW Google events, without old moved/skipped exceptions, invitations or reminders? "
                 "Recreate this event from Org as a NEW Google event, without old invitations or reminders? "))
        (user-error "Restoration cancelled; your Org version is still kept")))
    ;; Confirmation runs an event loop: recheck if background sync or editing changed the entry.
    (check)
    (my/org-calendar-auto--resolve marker "restore")))

(defun my/org-calendar-auto--review-time (payload)
  "Describe PAYLOAD's event range in local time, with explicit UTC offsets."
  (let* ((start (alist-get 'start payload)) (end (alist-get 'end payload))
         (date (alist-get 'date start)))
    (cond
     ((and date (alist-get 'date end))
      (let* ((parts (mapcar #'string-to-number (split-string (alist-get 'date end) "-")))
             (last (my/org-calendar-auto--day (nth 0 parts) (nth 1 parts) (nth 2 parts) -1)))
        (if (equal date last) (concat date " (all day)")
          (format "%s to %s (all day; includes final day)" date last))))
     ((and (alist-get 'dateTime start) (alist-get 'dateTime end))
      (let* ((begin (parse-iso8601-time-string (alist-get 'dateTime start)))
             (finish (parse-iso8601-time-string (alist-get 'dateTime end)))
             (begin-zone (format-time-string "%z" begin))
             (end-zone (format-time-string "%z" finish))
             (offset (lambda (zone) (concat "UTC" (substring zone 0 3) ":" (substring zone 3)))))
        (if (equal begin-zone end-zone)
            (format "%s to %s (%s)"
                    (format-time-string "%Y-%m-%d %a %H:%M" begin)
                    (format-time-string
                     (if (equal (format-time-string "%F" begin) (format-time-string "%F" finish))
                         "%H:%M" "%Y-%m-%d %a %H:%M") finish)
                    (funcall offset begin-zone))
          (format "%s (%s) to %s (%s)"
                  (format-time-string "%Y-%m-%d %a %H:%M" begin) (funcall offset begin-zone)
                  (format-time-string "%Y-%m-%d %a %H:%M" finish) (funcall offset end-zone)))))
     (t "(not available)"))))

(defun my/org-calendar-auto--review-fields (payload)
  "Return reader-facing values for only the fields this workflow synchronizes."
  (let ((zone (alist-get 'timeZone (alist-get 'start payload)))
        (end-zone (alist-get 'timeZone (alist-get 'end payload))))
    `(("Title" . ,(or (alist-get 'summary payload) ""))
      ("When" . ,(my/org-calendar-auto--review-time payload))
      ("Location" . ,(or (alist-get 'location payload) ""))
      ("Description" . ,(or (alist-get 'description payload) ""))
      ("Availability" . ,(if (equal (alist-get 'transparency payload) "transparent") "Free" "Busy"))
      ("Repeat rule" . ,(mapconcat #'identity (append (alist-get 'recurrence payload) nil) "\n"))
      ("Series timezone" . ,(if (and zone end-zone (not (equal zone end-zone)))
                                (format "Start: %s; end: %s" zone end-zone) (or zone end-zone "")))
      ("Status" . ,(if (equal (alist-get 'status payload) "cancelled") "Cancelled" "Active")))))

(defun my/org-calendar-auto--insert-comparison (local remote scope)
  "Show changed fields in LOCAL versus REMOTE, not Google's API metadata.
LOCAL can be an Org payload alist or a Google-shaped occurrence plist.
SCOPE explains whether choices affect one event, one occurrence, or a series."
  (let* ((org-payload (if (keywordp (car local))
                          (if (equal (plist-get local :status) "cancelled")
                              (let ((payload (copy-tree (my/org-calendar-auto--remote-payload
                                                         (plist-put (copy-tree local) :status "confirmed")))))
                                (setf (alist-get 'status payload) "cancelled")
                                payload)
                            (my/org-calendar-auto--remote-payload local)) local))
         (deleted (or (null remote) (equal (plist-get remote :status) "cancelled")))
         (org-fields (my/org-calendar-auto--review-fields org-payload))
         (google-fields (unless deleted
                          (my/org-calendar-auto--review-fields (my/org-calendar-auto--remote-payload remote))))
         (changed (if deleted '("Status")
                    (cl-loop for (label . value) in org-fields
                             unless (equal value (cdr (assoc label google-fields))) collect label))))
    (insert (propertize (concat "Scope: " scope "\n") 'face 'bold))
    (unless (or (member "When" changed) (equal (cdr (assoc "When" org-fields)) "(not available)"))
      (insert "When: " (cdr (assoc "When" org-fields)) "\n"))
    (if deleted
        (insert "Google deleted or cancelled this event. Your local version is kept for review.\n")
      (insert (format "%d changed field%s. Other synced fields match.\n"
                      (length changed) (if (= (length changed) 1) "" "s"))))
    (insert "\n")
    (dolist (label changed)
      (insert (propertize (concat label "\n") 'face 'bold))
      (dolist (version `(("Org" ,org-fields diff-removed) ("Google" ,google-fields diff-added)))
        (let ((value (if (and deleted (equal (car version) "Google")) "Deleted in Google"
                       (cdr (assoc label (nth 1 version))))))
          (insert (format "  %-8s" (concat (car version) ":"))
                  (propertize (replace-regexp-in-string
                               "\n" "\n          " (if (or (null value) (string-empty-p value)) "(empty)" value))
                              'face (nth 2 version)) "\n")))
      (insert "\n"))))

(defun my/org-calendar-auto--insert-choice (label action explanation)
  "Insert a resolution button with an explicit explanation of its effect."
  (insert-text-button label 'action action 'follow-link t)
  (insert "\n  " explanation "\n\n"))

(defun my/org-calendar-auto-review ()
  "Show sync status and both conflict versions, with resolution buttons."
  (interactive)
  (my/org-calendar-repeat--ensure-state)
  (let (conflicts errors)
    (with-current-buffer (my/org-calendar-auto--buffer)
      (org-with-wide-buffer
       (org-map-entries
        (lambda ()
          (when-let* ((error-text (org-entry-get nil "GCAL_AUTO_ERROR")))
            (push (concat (org-get-heading t t t t) ": " error-text) errors))
          (when-let* ((remote (org-entry-get nil "GCAL_AUTO_CONFLICT")))
            (push (list (point-marker) (org-get-heading t t t t)
                        (my/org-calendar-auto--local-payload) (my/org-calendar-auto--decode remote)) conflicts)))
        nil 'file)))
    (with-current-buffer (get-buffer-create "*Personal Calendar Sync*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Personal calendar: " my/org-calendar-auto-status "\n")
        (let ((count (+ (length conflicts)
                        (cl-count-if (lambda (job) (plist-get job :conflict)) my/org-calendar-repeat--pending))))
          (if (> count 0)
              (insert (format "%d conflict%s. Choose one version for all synced fields; private notes are kept.\n"
                              count (if (= count 1) "" "s"))
                      "Times below use this Mac's local timezone.\n\n")
            (insert "Saved events sync automatically. CANCELLED cancels on Google.\n"
                    (if my/org-calendar-keychain-enabled
                        "Keychain unlock is enabled; background refresh doesn't need a passphrase.\n"
                      "SPC n g k remembers the unlock in Keychain; SPC n g l unlocks only this session.\n")
                    "SPC n g m c cancels a pending login.\n\n")))
        (when my/org-calendar-auto--last-error (insert my/org-calendar-auto--last-error "\n\n"))
        (dolist (error-text errors) (insert error-text "\n"))
        (when errors (insert "\n"))
        (unless (or conflicts (seq-some (lambda (job) (plist-get job :conflict)) my/org-calendar-repeat--pending))
          (insert "No unresolved conflicts.\n"))
        (dolist (conflict (nreverse conflicts))
          (let* ((marker (nth 0 conflict)) (local (nth 2 conflict)) (remote (nth 3 conflict))
                 (deleted (or (null remote) (equal (plist-get remote :status) "cancelled")))
                 (series (org-with-point-at marker (org-entry-get nil "GCAL_AUTO_RECURRING")))
                 (identity (org-with-point-at marker (my/org-calendar-auto--record))))
            (insert (propertize (concat (nth 1 conflict) "\n") 'face 'org-level-2))
            (my/org-calendar-auto--insert-comparison local remote (if series "Entire recurring series" "This event"))
            (unless deleted
              (my/org-calendar-auto--insert-choice
               "Keep Org" (lambda (_) (my/org-calendar-auto--resolve marker "org"))
               (if (equal (alist-get 'status local) "cancelled")
                   "Cancel on Google, keeping the local heading and private notes."
                  "Update Google with the Org version.")))
            (when (and deleted (not (equal (alist-get 'status local) "cancelled"))
                       (not (org-with-point-at marker (org-entry-get nil "GCAL_AUTO_SERIES"))))
              (let ((old-id (plist-get identity :id)) (hash (plist-get identity :hash))
                    (snapshot (plist-get identity :conflict)))
                (my/org-calendar-auto--insert-choice
                 (if series "Recreate series from Org" "Restore as a new Google event")
                 (lambda (_) (my/org-calendar-auto--queue-restore marker old-id hash snapshot))
                 (if series
                     "Recreate the saved rule and event fields with a new ID. Old exceptions, invitations and reminders are not recovered. Confirmation required."
                   "Recreate the saved Org event with a new Google ID. Old invitations and reminders are not recovered. Confirmation required."))))
            (my/org-calendar-auto--insert-choice
             (if deleted "Accept Google deletion" "Use Google")
             (lambda (_) (my/org-calendar-auto--resolve marker "google"))
             (if deleted "Mark the local heading CANCELLED; keep its heading and private notes."
               "Replace Org's synced fields with the Google version."))))
        (my/org-calendar-repeat-review))
      (special-mode))
    (pop-to-buffer "*Personal Calendar Sync*")))

(defun my/org-calendar-auto--auth-finished (success _background)
  (if success
      (progn (my/org-calendar-auto--status "pending") (my/org-calendar-auto--schedule))
    (my/org-calendar-auto--status
     (if (and (my/org-calendar-unlock-available-p) (eq my/org-calendar-auth-problem 'temporary))
         "pending" "needs login"))))

(defun my/org-calendar-auto--manual-fetch (original &rest args)
  (if my/org-calendar-auto-mode
      (progn (my/org-calendar-auto--schedule) (message "Calendar sync queued; SPC n g s shows status"))
    (apply original args)))

(defun my/org-calendar-auto--manual-publish (original &rest args)
  (if (not my/org-calendar-auto-mode) (apply original args)
    (org-with-point-at (my/org-calendar-event-marker)
      (unless (my/org-calendar-auto--file-p) (user-error "Only personal test events sync automatically"))
      (my/org-calendar-auto--local-payload)
      (save-buffer))
    (my/org-calendar-auto--schedule)))

(defun my/org-calendar-auto--manual-cancel (original &rest args)
  (if (not my/org-calendar-auto-mode) (apply original args)
    (if (my/org-calendar-repeat--selected)
        (my/org-calendar-repeat--todo #'ignore)
    (org-with-point-at (my/org-calendar-event-marker)
      (unless (my/org-calendar-auto--file-p) (user-error "Only personal test events sync automatically"))
      (my/org-calendar-auto--local-payload)
      (org-todo "CANCELLED")
      (save-buffer))
    (my/org-calendar-auto--schedule))))

(define-minor-mode my/org-calendar-auto-mode
  "Automatically reconcile saved personal events; never sync Work or task files."
  :global t
  :group 'my/org-calendar-auto
  (cl-incf my/org-calendar-auto--generation)
  (dolist (timer (list my/org-calendar-auto--timer my/org-calendar-auto--debounce))
    (when (timerp timer) (cancel-timer timer)))
  (when my/org-calendar-auto--response (request-abort my/org-calendar-auto--response))
  (setq my/org-calendar-auto--busy nil my/org-calendar-auto--rerun nil)
  (if my/org-calendar-auto-mode
      (progn
        (my/org-calendar-prepare)
        (setq my/org-calendar-auto--calendar my/org-gcal-test-calendar-id
              my/org-calendar-auto--file (my/org-file "calendar-personal.org"))
        (add-hook 'after-save-hook #'my/org-calendar-auto--after-save)
        (add-hook 'org-capture-after-finalize-hook #'my/org-calendar-auto--schedule)
        (add-hook 'org-agenda-mode-hook #'my/org-calendar-auto--agenda-open)
        (add-hook 'org-agenda-finalize-hook #'my/org-calendar-auto--agenda-open)
        (add-hook 'doom-switch-buffer-hook #'my/org-calendar-auto--agenda-open)
        (add-hook 'my/org-calendar-auth-finished-hook #'my/org-calendar-auto--auth-finished)
        (advice-add 'org-agenda-todo :around #'my/org-calendar-auto--agenda-todo)
        (advice-add 'my/org-calendar-fetch :around #'my/org-calendar-auto--manual-fetch)
        (advice-add 'my/org-calendar-publish :around #'my/org-calendar-auto--manual-publish)
        (advice-add 'my/org-calendar-cancel :around #'my/org-calendar-auto--manual-cancel)
        (add-to-list 'global-mode-string '(:eval (when my/org-calendar-auto-mode
                                                (concat " Cal: " my/org-calendar-auto-status))))
        (setq my/org-calendar-auto--timer (run-at-time 300 300 #'my/org-calendar-auto--start))
        (my/org-calendar-auto--schedule))
    (dolist (timer (list my/org-calendar-auto--timer my/org-calendar-auto--debounce))
      (when (timerp timer) (cancel-timer timer)))
    (when my/org-calendar-auto--response (request-abort my/org-calendar-auto--response))
    (setq my/org-calendar-auto--busy nil my/org-calendar-auto--rerun nil)
    (remove-hook 'after-save-hook #'my/org-calendar-auto--after-save)
    (remove-hook 'org-capture-after-finalize-hook #'my/org-calendar-auto--schedule)
    (remove-hook 'org-agenda-mode-hook #'my/org-calendar-auto--agenda-open)
    (remove-hook 'org-agenda-finalize-hook #'my/org-calendar-auto--agenda-open)
    (remove-hook 'doom-switch-buffer-hook #'my/org-calendar-auto--agenda-open)
    (remove-hook 'my/org-calendar-auth-finished-hook #'my/org-calendar-auto--auth-finished)
    (advice-remove 'org-agenda-todo #'my/org-calendar-auto--agenda-todo)
    (advice-remove 'my/org-calendar-fetch #'my/org-calendar-auto--manual-fetch)
    (advice-remove 'my/org-calendar-publish #'my/org-calendar-auto--manual-publish)
    (advice-remove 'my/org-calendar-cancel #'my/org-calendar-auto--manual-cancel)
    (my/org-calendar-auto--status "paused")))

(provide 'org-calendar-auto)
(load (expand-file-name "org-calendar-repeat.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)
