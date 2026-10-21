;;; org-tasks-sync.el --- Saved Personal tasks and a phone checklist -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'org)
(require 'org-id)
(require 'org-agenda)
(require 'calendar)
(require 'button)
(load (expand-file-name "org-tasks-access.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)
(declare-function my/org-file "config" (name))
(declare-function my/org-background-buffer "org-calendar-config" (file))
(declare-function my/org-background-release "org-calendar-config" (file))
(declare-function my/org-calendar-status-icon "org-calendar-status" (spec))
(declare-function my/org-calendar-auto--refresh-agendas "org-calendar-auto" ())
(declare-function my/org-calendar-view-refresh-visible "org-calendar-view" (&rest args))

(defvar my/org-tasks-list-id nil "Exact list ID approved in private Tasks settings.")
(defvar my/org-tasks-account nil "Exact approved Personal account, never a Work account.")
(defvar my/org-tasks-settings-file
  (expand-file-name "org-tasks.el" (file-name-directory my/org-calendar-settings-file)))
(defvar my/org-tasks-mode nil)
(defvar my/org-tasks-status "paused")
(defvar my/org-tasks--scope nil)
(defvar my/org-tasks--account nil)
(defvar my/org-tasks--list nil)
(defvar my/org-tasks--file nil)
(defvar my/org-tasks--state-file nil)
(defvar my/org-tasks--state nil)
(defvar my/org-tasks--timer nil)
(defvar my/org-tasks--debounce nil)
(defvar my/org-tasks--busy nil)
(defvar my/org-tasks--running nil)
(defvar my/org-tasks--response nil)
(defvar my/org-tasks--generation 0)
(defvar my/org-tasks--saving nil)
(defvar my/org-tasks--refreshing nil)
(defvar my/org-tasks--error nil)
(defvar my/org-tasks--last-run nil)
(defvar my/org-tasks--last-success nil)
(defvar my/org-tasks--lock nil)
(defvar my/org-tasks--locals nil)
(defvar my/org-tasks--remote nil)
(defvar my/org-tasks--rerun nil)
(defconst my/org-tasks--fields "id,title,due,status,deleted,etag,parent,assignmentInfo")

(defun my/org-tasks--status (status)
  "Show quiet STATUS, notifying once when review or login becomes necessary."
  (unless (equal status my/org-tasks-status)
    (when (member status '("needs attention" "needs login"))
      (message "Personal tasks %s; SPC n i opens Integrations" status)))
  (setq my/org-tasks-status status)
  (force-mode-line-update t))

(defun my/org-tasks--scope-id ()
  "Bind list, verified account, and exact Personal file into one cache identity."
  (secure-hash 'sha256 (json-encode (list my/org-tasks-account my/org-tasks-list-id
                                        (file-truename (my/org-file "personal.org"))))))

(defun my/org-tasks--check-scope ()
  "Refuse changed mappings, Work files, and unapproved accounts before any IO."
  (unless (and (equal my/org-tasks--account my/org-calendar-approved-primary-id)
               (equal my/org-tasks--account my/org-tasks-account)
               (equal my/org-tasks--list my/org-tasks-list-id)
               (equal my/org-tasks--file (file-truename (my/org-file "personal.org")))
               (not (seq-some (lambda (name)
                                (or (equal my/org-tasks--file (file-truename (my/org-file name)))
                                    (file-equal-p my/org-tasks--file (my/org-file name))))
                              '("work.org" "calendar-work.org" "calendar-personal.org")))
               (equal my/org-tasks--scope (my/org-tasks--scope-id)))
    (user-error "Tasks mapping changed; pause sync and review the private settings")))

(defun my/org-tasks--buffer ()
  "Return only the pinned Personal task buffer, with external changes guarded."
  (my/org-tasks--check-scope)
  (let ((buffer (my/org-background-buffer my/org-tasks--file)))
    (with-current-buffer buffer
      (unless (verify-visited-file-modtime buffer)
        (user-error "personal.org changed on disk; review or revert it before syncing")))
    buffer))

(defun my/org-tasks--personal-buffer-p ()
  "Accept only the exact Personal source, including a verified filesystem alias."
  (and my/org-tasks--file buffer-file-name
       (or (equal (expand-file-name buffer-file-name) my/org-tasks--file)
           (file-equal-p buffer-file-name my/org-tasks--file))))

(defun my/org-tasks--store ()
  "Atomically save private sync state before sending remote mutations."
  (my/org-tasks--check-scope)
  (let* ((directory (file-name-directory my/org-tasks--state-file)) temporary)
    (make-directory directory t)
    (set-file-modes directory #o700)
    (setq temporary (make-temp-file (expand-file-name ".tasks-state-" directory)))
    (unwind-protect
        (progn
          (write-region
           (json-encode (list :version 1 :scope my/org-tasks--scope
                              :initialized (plist-get my/org-tasks--state :initialized)
                              :ignored (vconcat (plist-get my/org-tasks--state :ignored))
                              :records (vconcat
                                        (mapcar (lambda (record)
                                                  (let ((copy (copy-tree record)))
                                                    (when (plist-member copy :candidates)
                                                      (setq copy (plist-put copy :candidates
                                                                            (vconcat (plist-get copy :candidates)))))
                                                    copy))
                                                (plist-get my/org-tasks--state :records)))))
           nil temporary nil 'silent)
          (set-file-modes temporary #o600)
          (rename-file temporary my/org-tasks--state-file t))
      (when (file-exists-p temporary) (delete-file temporary)))))

(defun my/org-tasks--load-state ()
  "Read JSON as data, rejecting corrupt or cross-account cache identities."
  (setq my/org-tasks--state
        (if (file-exists-p my/org-tasks--state-file)
            (with-temp-buffer
              (insert-file-contents my/org-tasks--state-file)
              (json-parse-buffer :object-type 'plist :array-type 'list :null-object nil :false-object nil))
          (list :version 1 :scope my/org-tasks--scope :initialized nil :records nil :ignored nil)))
  (unless (and (equal (plist-get my/org-tasks--state :version) 1)
               (equal (plist-get my/org-tasks--state :scope) my/org-tasks--scope)
               (listp (plist-get my/org-tasks--state :records)))
    (user-error "Tasks cache is invalid; do not delete it or retry creations blindly"))
  (let (keys ids)
    (dolist (record (plist-get my/org-tasks--state :records))
      (let ((key (plist-get record :key)) (id (plist-get record :id)))
        (unless (and (stringp key) (not (member key keys))
                     (or (null id) (and (stringp id) (not (member id ids)))))
          (user-error "Tasks cache contains duplicate identities; review it before syncing"))
        (push key keys) (when id (push id ids))))))

(defun my/org-tasks--record (key)
  (seq-find (lambda (record) (equal key (plist-get record :key)))
            (plist-get my/org-tasks--state :records)))

(defun my/org-tasks--put (key property value)
  "Set PROPERTY on KEY's record while preserving pending work."
  (let ((record (my/org-tasks--record key)))
    (unless record
      (setq record (list :key key))
      (setf (plist-get my/org-tasks--state :records)
            (append (plist-get my/org-tasks--state :records) (list record))))
    (let ((updated (plist-put record property value)))
      (setf (plist-get my/org-tasks--state :records)
            (mapcar (lambda (item) (if (equal key (plist-get item :key)) updated item))
                    (plist-get my/org-tasks--state :records)))
      updated)))

(defun my/org-tasks--day (timestamp)
  "Read a civil date literally; never translate a scheduled day through UTC."
  (when timestamp
    (unless (string-match "\\`<?\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)" timestamp)
      (user-error "Task has an invalid scheduled day"))
    (let* ((day (match-string 1 timestamp))
           (parts (mapcar #'string-to-number (split-string day "-"))))
      (unless (calendar-date-is-valid-p (list (nth 1 parts) (nth 2 parts) (car parts)))
        (user-error "Task has an invalid calendar date"))
      day)))

(defun my/org-tasks--remote-payload (task)
  "Keep only the shared checklist fields from TASK, never Google notes."
  (if (plist-get task :deleted) '(:deleted t)
    (list :title (replace-regexp-in-string "[\r\n]+" " " (or (plist-get task :title) ""))
          :day (my/org-tasks--day (plist-get task :due))
          :status (or (plist-get task :status) "needsAction"))))

(defun my/org-tasks--local (marker)
  "Read MARKER's shared fields and a hash of its complete saved local version."
  (when (and (markerp marker) (marker-buffer marker))
    (org-with-point-at marker
      (when (and (my/org-tasks--personal-buffer-p) (equal (org-get-category) "Personal")
                 (member (org-get-todo-state) '("TODO" "DOING" "WAIT" "DONE" "CANCELLED")))
        (let ((title (my/org-tasks--title)) (state (org-get-todo-state)))
          (unless (and (or (not (string-empty-p title)) (org-entry-get nil "GTASK_ID")) (<= (length title) 1024))
            (user-error "Task title must contain 1 to 1024 characters"))
          (list :marker marker :state state
                :payload (list :title title :day (my/org-tasks--day (org-entry-get nil "SCHEDULED"))
                               :status (cond ((equal state "DONE") "completed")
                                             ((equal state "CANCELLED") "cancelled") (t "needsAction")))
                :version (secure-hash 'sha256 (buffer-substring-no-properties
                                              (point) (save-excursion (org-end-of-subtree t t) (point))))))))))

(defun my/org-tasks--title ()
  "Keep literal phone titles, even when Org interprets their trailing tag syntax."
  (let ((heading (org-get-heading t t t t)))
    (if (equal heading (org-entry-get nil "GTASK_DISPLAY_TITLE"))
        (or (org-entry-get nil "GTASK_RAW_TITLE") heading) heading)))

(defun my/org-tasks--property (name value)
  "Write display/sync metadata only when its value actually changes."
  (unless (equal value (org-entry-get nil name)) (org-entry-put nil name value)))

(defun my/org-tasks--marker (key)
  "Find one local identity without refiling, categorizing, or touching Work."
  (with-current-buffer (my/org-tasks--buffer)
    (org-with-wide-buffer
     (let (result)
       (org-map-entries (lambda () (when (equal (org-entry-get nil "GTASK_KEY") key)
                                    (if result (user-error "Duplicate task identity")
                                      (setq result (point-marker))))) nil 'file)
       result))))

(defun my/org-tasks--collect ()
  "Enroll saved Personal tasks with stable keys before remote creation."
  (with-current-buffer (my/org-tasks--buffer)
    (org-with-wide-buffer
     (let ((before (copy-tree my/org-tasks--state)) keys ids markers)
       (condition-case problem
           (atomic-change-group
             (org-map-entries
              (lambda ()
                (when (and (org-get-todo-state) (equal (org-get-category) "Personal"))
                  (let* ((key (or (org-entry-get nil "GTASK_KEY") (org-id-new)))
                         (id (org-entry-get nil "GTASK_ID"))
                         (record (my/org-tasks--record key)) (state (org-get-todo-state)))
                    (when (or (member key keys) (and id (member id ids)))
                      (user-error "Duplicate task identity; do not copy linked headings"))
                    (push key keys) (when id (push id ids))
                    (my/org-tasks--property "GTASK_KEY" key)
                    (unless record
                      (my/org-tasks--put key :id id)
                      (when (equal state "CANCELLED")
                        (my/org-tasks--put key :ignored t)))
                    (when (member state '("TODO" "DOING" "WAIT"))
                      (my/org-tasks--put key :ignored nil)
                      (my/org-tasks--put key :open-state state))
                    (when (and id (plist-get record :id) (not (equal id (plist-get record :id))))
                      (user-error "Task identity does not match its private cache"))
                    (let ((marker (point-marker)))
                      (unless (my/org-tasks--local marker) (user-error "Unsupported Personal task state"))
                      (push (cons key marker) markers))))) nil 'file))
         (error (setq my/org-tasks--state before) (signal (car problem) (cdr problem))))
       (when (buffer-modified-p) (let ((my/org-tasks--saving t)) (save-buffer)))
       (setq my/org-tasks--locals
             (mapcar (lambda (item) (cons (car item) (my/org-tasks--local (cdr item)))) markers))
       (my/org-tasks--store)))))

(defun my/org-tasks--merge (base local remote)
  "Merge independent shared edits; report fields changed differently on both sides."
  (let (payload conflicts)
    (dolist (field '(:title :day :status))
      (let ((old (plist-get base field)) (here (plist-get local field)) (there (plist-get remote field)))
        (setq payload (plist-put payload field
                                 (cond ((equal here there) here)
                                       ((and base (equal here old)) there)
                                       ((and base (equal there old)) here)
                                       (t (push field conflicts) here))))))
    (list :payload payload :conflicts (nreverse conflicts))))

(defun my/org-tasks--safe-local (local)
  (let ((marker (plist-get local :marker)))
    (and marker (marker-buffer marker) (not (buffer-modified-p (marker-buffer marker)))
         (verify-visited-file-modtime (marker-buffer marker))
         (equal (plist-get local :version) (plist-get (my/org-tasks--local marker) :version)))))

(defun my/org-tasks--schedule-day (day)
  "Change only the scheduled day, retaining local time, duration, and repeater."
  (let* ((old (org-entry-get nil "SCHEDULED"))
         (template (or old (org-entry-get nil "GTASK_LOCAL_SCHEDULE"))))
    (unless (equal day (my/org-tasks--day old))
      (when old (my/org-tasks--property "GTASK_LOCAL_SCHEDULE" old))
      (if (null day) (org-add-planning-info nil nil 'scheduled)
        (let* ((parts (mapcar #'string-to-number (split-string day "-")))
               (weekday (format-time-string "%a" (encode-time 0 0 12 (nth 2 parts) (nth 1 parts) (car parts))))
               (stamp (if (and template (string-match "\\`<[0-9-]+[ 	]+[^ 	>]+" template))
                          (concat "<" day " " weekday (substring template (match-end 0)))
                        (format "<%s %s>" day weekday))))
          (org-add-planning-info 'scheduled day)
          (save-excursion
            (org-back-to-heading t) (forward-line)
            (unless (re-search-forward org-scheduled-time-regexp (line-end-position) t)
              (error "Scheduled field was not inserted"))
            ;; Org's capture group is the timestamp contents, not its brackets.
            (replace-match (substring stamp 1 -1) t t nil 1)))))))

(defun my/org-tasks--apply (key local payload)
  "Apply shared PAYLOAD only to the exact clean LOCAL version, preserving notes."
  (when (my/org-tasks--safe-local local)
    (org-with-point-at (plist-get local :marker)
      (let ((org-inhibit-logging t) (org-log-repeat nil))
        (unless (plist-get payload :deleted)
          (unless (equal (my/org-tasks--title) (plist-get payload :title))
            (org-edit-headline (if (string-empty-p (plist-get payload :title)) "(untitled task)" (plist-get payload :title))))
          (unless (equal (org-get-heading t t t t) (plist-get payload :title))
            (my/org-tasks--property "GTASK_RAW_TITLE" (plist-get payload :title))
            (my/org-tasks--property "GTASK_DISPLAY_TITLE" (org-get-heading t t t t)))
          (my/org-tasks--schedule-day (plist-get payload :day)))
        (let* ((record (my/org-tasks--record key))
               (desired (cond ((plist-get payload :deleted) "CANCELLED")
                              ((equal (plist-get payload :status) "completed") "DONE")
                              ((member (org-get-todo-state) '("TODO" "DOING" "WAIT")) (org-get-todo-state))
                              (t (or (plist-get record :open-state) "TODO")))))
          (unless (equal desired (org-get-todo-state))
            (org-todo desired)
            (when (member desired '("TODO" "DOING" "WAIT"))
              (org-add-planning-info nil nil 'closed)))
          (when-let* ((id (plist-get record :id))) (my/org-tasks--property "GTASK_ID" id)))
        (when (buffer-modified-p) (let ((my/org-tasks--saving t)) (save-buffer)))))
    (unless (or (plist-get payload :deleted)
                (equal payload (plist-get (my/org-tasks--local (plist-get local :marker)) :payload)))
      ;; A local Org repeater may have advanced after a phone completion.
      (setq my/org-tasks--rerun t))
    t))

(defun my/org-tasks--request (method id payload etag callback &optional params)
  "Call only the pinned list's task endpoint; writes use the current ETag."
  (my/org-tasks--check-scope)
  (unless (and my/org-tasks-mode (my/org-tasks-session-ready-p)) (user-error "Tasks sync is paused or needs login"))
  (unless (member method '("GET" "POST" "PATCH" "DELETE")) (error "Unsupported Tasks operation"))
  (when (and (member method '("PATCH" "DELETE")) (not (stringp etag)))
    (user-error "Google task has no ETag; refusing an unguarded write"))
  (let ((generation my/org-tasks--generation) (scope my/org-tasks--scope))
    (setq my/org-tasks--response
          (request (concat "https://tasks.googleapis.com/tasks/v1/lists/"
                           (url-hexify-string my/org-tasks--list) "/tasks"
                           (when id (concat "/" (url-hexify-string id))))
                   :type method :timeout 20 :params params
                   :headers (append `(("Authorization" . ,(concat "Bearer " my/org-tasks-access-token))
                                      ("Content-Type" . "application/json; charset=utf-8"))
                                    (when etag (list (cons "If-Match" etag))))
                   :data (when payload (encode-coding-string (json-encode payload) 'utf-8))
                   :parser (lambda () (skip-chars-forward " \t\r\n")
                             (unless (eobp) (json-parse-buffer :object-type 'plist :array-type 'list
                                                             :null-object nil :false-object nil)))
                   :complete (cl-function
                              (lambda (&key response data &allow-other-keys)
                                (when (and my/org-tasks-mode (= generation my/org-tasks--generation))
                                  (condition-case nil
                                      (progn
                                        (unless (equal scope (my/org-tasks--scope-id))
                                          (user-error "Tasks mapping changed during the request"))
                                        (funcall callback (request-response-status-code response) data))
                                    (error (setq my/org-tasks--error "Tasks response could not be applied safely; local changes were kept")
                                           (my/org-tasks--finish "needs attention"))))))))))

(defun my/org-tasks--api-payload (payload)
  "Serialize the three shared fields only; nil due explicitly unschedules a task."
  `((title . ,(plist-get payload :title)) (status . ,(plist-get payload :status))
    (due . ,(when-let* ((day (plist-get payload :day))) (concat day "T00:00:00.000Z")))))

(defun my/org-tasks--issue (key text)
  (my/org-tasks--put key :issue text))

(defun my/org-tasks--failure (status &optional data)
  "Keep safe HTTP STATUS and permission reasons from DATA for an explicit retry."
  (when (eq status 401) (setq my/org-tasks-access-token nil my/org-tasks-token-expiration nil))
  (when (eq status 403)
    (setq my/org-tasks-access-error-reasons
          (delq nil (mapcar (lambda (item) (plist-get item :reason))
                           (append (plist-get (plist-get data :error) :errors)
                                   (plist-get (plist-get data :error) :details))))))
  (setq my/org-tasks--error
        (cond ((and (eq status 403)
                    (member "ACCESS_TOKEN_SCOPE_INSUFFICIENT" my/org-tasks-access-error-reasons))
               "Google Tasks permission was not granted. Open Integrations and authorize Tasks.")
              ((eq status 403) "Google Tasks access is denied. Open Integrations and check Tasks authorization.")
              ((eq status 400) "Google rejected a task update; review its shared fields")
              (t "Tasks could not be reached; saved changes are kept and will retry automatically")))
  (my/org-tasks--finish (if (memq status '(400 403)) "needs attention" "pending")))

(defun my/org-tasks--accept (key local task next)
  "Persist a confirmed server identity before attempting any source-buffer change."
  (let ((payload (my/org-tasks--remote-payload task)))
    (my/org-tasks--put key :id (plist-get task :id))
    (my/org-tasks--put key :etag (plist-get task :etag))
    (my/org-tasks--put key :creating nil)
    (my/org-tasks--put key :resolution nil)
    (my/org-tasks--put key :issue nil)
    (my/org-tasks--store)
    (if (my/org-tasks--apply key local payload)
        (progn (my/org-tasks--put key :base payload) (my/org-tasks--store))
      ;; Keep the previous common version so a late local edit cannot erase
      ;; a phone edit that was merged into the confirmed server response.
      (setq my/org-tasks--rerun t))
    (funcall next)))

(defun my/org-tasks--create (key local next)
  "Journal creation before POST; an uncertain result is never blindly retried."
  (let ((payload (plist-get local :payload)))
    (my/org-tasks--put key :creating payload)
    (my/org-tasks--store)
    (my/org-tasks--request
     "POST" nil (my/org-tasks--api-payload payload) nil
     (lambda (status task)
       (if (and (memq status '(200 201)) (stringp (plist-get task :id)))
           (my/org-tasks--accept key local task next)
         (when (memq status '(400 401 403 404))
           (my/org-tasks--put key :creating nil) (my/org-tasks--store))
         (my/org-tasks--issue key "Creation reply was not confirmed. Check Google before linking or retrying this task")
         (my/org-tasks--store)
         (my/org-tasks--failure status task))))))

(defun my/org-tasks--update (key local payload task next)
  "PATCH only shared fields, guarding phone changes with the observed ETag."
  (my/org-tasks--request
   "PATCH" (plist-get task :id) (my/org-tasks--api-payload payload) (plist-get task :etag)
   (lambda (status response)
     (cond ((eq status 200) (my/org-tasks--accept key local response next))
           ((eq status 412) (my/org-tasks--issue key "Google changed during sync; both versions were kept")
            (my/org-tasks--store) (funcall next))
           (t (my/org-tasks--failure status response))))))

(defun my/org-tasks--delete (key local task next)
  "Delete one reviewed Google task, never silently deleting a parent's subtasks."
  (if (seq-some (lambda (item) (and (equal (plist-get item :parent) (plist-get task :id))
                                   (not (plist-get item :deleted)))) my/org-tasks--remote)
      (progn (my/org-tasks--issue key "This task has Google subtasks; handle their deletion on your phone") (funcall next))
    (my/org-tasks--request
     "DELETE" (plist-get task :id) nil (plist-get task :etag)
     (lambda (status response)
       (cond ((eq status 204)
              (my/org-tasks--put key :closed t)
              (my/org-tasks--put key :base '(:deleted t))
              (my/org-tasks--put key :resolution nil)
              (my/org-tasks--put key :issue nil)
              (my/org-tasks--store)
              (when local (my/org-tasks--apply key local '(:deleted t)))
              (funcall next))
             ((eq status 412) (my/org-tasks--issue key "Google changed; review deletion again") (funcall next))
             (t (my/org-tasks--failure status response)))))))

(defun my/org-tasks--process (key local task next)
  "Reconcile one record without silently resolving conflicts or deletion scope."
  (let* ((record (my/org-tasks--record key))
         (id (plist-get record :id))
         (remote (and task (my/org-tasks--remote-payload task)))
         (payload (plist-get local :payload))
         (resolution (plist-get record :resolution))
         (choice (plist-get resolution :choice)))
    (my/org-tasks--put key :remote remote)
    (my/org-tasks--put key :remote-etag (plist-get task :etag))
    (my/org-tasks--put key :last-local payload)
    (my/org-tasks--put key :local-version (plist-get local :version))
    (my/org-tasks--put key :issue nil)
    (cond
     ((or (plist-get record :detached) (and (plist-get record :ignored) (not id))) (funcall next))
     ((and (plist-get record :closed) (or (null local) (equal (plist-get payload :status) "cancelled"))) (funcall next))
     ((or (buffer-modified-p (my/org-tasks--buffer))
          (if local (not (my/org-tasks--safe-local local))
            (my/org-tasks--local (my/org-tasks--marker key))))
      ;; Recheck after network reads, especially before a reviewed deletion.
      (setq my/org-tasks--rerun t) (funcall next))
     ((and resolution
           (not (and (equal (plist-get resolution :local-version) (plist-get local :version))
                     (equal (plist-get resolution :remote) remote)
                     (equal (plist-get resolution :etag) (plist-get task :etag)))))
      (my/org-tasks--put key :resolution nil)
      (my/org-tasks--issue key "Task changed after the choice was made; review the current versions") (funcall next))
     ((equal choice "detach") (my/org-tasks--put key :detached t) (my/org-tasks--put key :resolution nil) (funcall next))
     ((and (equal choice "link") task local)
      (my/org-tasks--put key :id (plist-get task :id))
      (my/org-tasks--put key :base remote)
      (my/org-tasks--put key :creating nil)
      (my/org-tasks--put key :resolution nil)
      (my/org-tasks--store)
      (my/org-tasks--process key local task next))
     ((and (equal choice "delete") task (not (plist-get task :deleted)))
      (my/org-tasks--delete key local task next))
     ((and (equal choice "google") remote local)
      (when (my/org-tasks--apply key local remote)
        (my/org-tasks--put key :base remote) (my/org-tasks--put key :etag (plist-get task :etag))
        (my/org-tasks--put key :closed (plist-get remote :deleted))
        (my/org-tasks--put key :resolution nil)) (funcall next))
     ((and (equal choice "restore") local)
      (my/org-tasks--put key :id nil) (my/org-tasks--put key :closed nil)
      (my/org-tasks--create key local next))
     ((null local) (my/org-tasks--issue key "Task left personal.org or is no longer a Personal task; Google was not deleted") (funcall next))
     ((not id)
      (cond
       ((and (plist-get record :creating) (not (equal choice "retry")))
        (my/org-tasks--put key :candidates
                           (mapcar (lambda (item) (list :id (plist-get item :id) :etag (plist-get item :etag)
                                                       :payload (my/org-tasks--remote-payload item)))
                                   (seq-filter (lambda (item) (equal (my/org-tasks--remote-payload item)
                                                                    (plist-get record :creating))) my/org-tasks--remote)))
        (my/org-tasks--issue key "Creation reply was lost. Link an existing match or check Google before retrying") (funcall next))
       ((equal (plist-get payload :status) "cancelled") (funcall next))
       (t (my/org-tasks--create key local next))))
     ((or (plist-get task :assignmentInfo) (null task))
      (my/org-tasks--issue key "Assigned or unavailable Google task; no changes were sent") (funcall next))
     ((plist-get remote :deleted)
      (my/org-tasks--issue key "Google deleted this task. Accept deletion or restore it as a new task") (funcall next))
     ((equal (plist-get payload :status) "cancelled")
      (my/org-tasks--issue key "Cancellation is saved locally. Confirm Google deletion or keep the Google task") (funcall next))
     (t
      (let* ((merge (if (equal choice "org") (list :payload payload)
                      (my/org-tasks--merge (plist-get record :base) payload remote)))
             (merged (plist-get merge :payload)))
        (cond ((plist-get merge :conflicts)
               (my/org-tasks--issue key (format "Both sides changed: %s"
                                              (mapconcat (lambda (field) (substring (symbol-name field) 1))
                                                         (plist-get merge :conflicts) ", ")))
               (funcall next))
              ((not (equal merged remote)) (my/org-tasks--update key local merged task next))
              (t
               (when (my/org-tasks--apply key local remote)
                 (my/org-tasks--put key :base remote) (my/org-tasks--put key :etag (plist-get task :etag))
                 (my/org-tasks--put key :resolution nil))
               (funcall next))))))))

(defun my/org-tasks--queue (records)
  "Reconcile sequentially, verifying missing IDs rather than guessing deletion."
  (if (null records) (my/org-tasks--import)
    (let* ((key (plist-get (car records) :key))
           (id (or (plist-get (plist-get (car records) :resolution) :link-id) (plist-get (car records) :id)))
           (local (alist-get key my/org-tasks--locals nil nil #'equal))
           (task (seq-find (lambda (item) (equal id (plist-get item :id))) my/org-tasks--remote))
           (next (lambda () (my/org-tasks--queue (cdr records)))))
      (if (and id (null task) (not (plist-get (car records) :detached)))
          (my/org-tasks--request
           "GET" id nil nil
           (lambda (status response)
             (cond ((eq status 200) (my/org-tasks--process key local response next))
                   ((memq status '(404 410)) (my/org-tasks--process key local (list :id id :deleted t) next))
                   (t (my/org-tasks--failure status response))))
           `((fields . ,my/org-tasks--fields)))
        (my/org-tasks--process key local task next)))))

(defun my/org-tasks--import ()
  "Import new phone tasks under Tasks, leaving old hidden completions untouched."
  (let ((buffer (my/org-tasks--buffer)))
    (if (buffer-modified-p buffer) (setq my/org-tasks--rerun t)
      (with-current-buffer buffer
        (org-with-wide-buffer
         (save-excursion
           (dolist (task my/org-tasks--remote)
             (let ((id (plist-get task :id)) (payload (my/org-tasks--remote-payload task)))
               (unless (or (plist-get task :deleted) (plist-get task :assignmentInfo)
                           (seq-some (lambda (record) (or (equal id (plist-get record :id))
                                                         (equal payload (plist-get record :creating))))
                                     (plist-get my/org-tasks--state :records))
                           (and (member id (plist-get my/org-tasks--state :ignored))
                                (equal (plist-get payload :status) "completed")))
                 (goto-char (point-min))
                 (unless (re-search-forward "^\\* Tasks[ 	]*$" nil t)
                   (user-error "personal.org needs its existing Tasks heading for phone imports"))
                 (org-end-of-subtree t t)
                 (unless (bolp) (insert "\n"))
                 (let ((key (org-id-new)))
                   (insert "** TODO " (if (string-empty-p (plist-get payload :title)) "(untitled task)" (plist-get payload :title)) "\n")
                   (forward-line -1)
                   (org-entry-put nil "GTASK_KEY" key)
                   (org-entry-put nil "GTASK_ID" id)
                   (unless (equal (org-get-heading t t t t) (plist-get payload :title))
                     (org-entry-put nil "GTASK_RAW_TITLE" (plist-get payload :title))
                     (org-entry-put nil "GTASK_DISPLAY_TITLE" (org-get-heading t t t t)))
                   (my/org-tasks--put key :id id)
                   (my/org-tasks--put key :base payload)
                   (my/org-tasks--put key :etag (plist-get task :etag))
                   ;; Save identity before callbacks can observe the imported task.
                   (let ((my/org-tasks--saving t)) (save-buffer))
                   (my/org-tasks--store)
                   (my/org-tasks--apply key (my/org-tasks--local (point-marker)) payload)))))))))
    (my/org-tasks--store)
    (my/org-tasks--finish
     (if (seq-some (lambda (record) (plist-get record :issue)) (plist-get my/org-tasks--state :records))
         "needs attention" (if my/org-tasks--rerun "pending" "up to date")))))

(defun my/org-tasks--list (&optional page collected)
  "Fetch every page, including known tasks completed in Google's mobile client."
  (my/org-tasks--request
   "GET" nil nil nil
   (lambda (status data)
     (if (not (eq status 200)) (my/org-tasks--failure status data)
       (let ((tasks (append collected (plist-get data :items))))
         (if-let* ((next (plist-get data :nextPageToken))) (my/org-tasks--list next tasks)
           (setq my/org-tasks--remote tasks)
           (unless (plist-get my/org-tasks--state :initialized)
             (setf (plist-get my/org-tasks--state :ignored)
                   (mapcar (lambda (task) (plist-get task :id))
                           (seq-filter (lambda (task) (equal (plist-get task :status) "completed")) tasks))
                   (plist-get my/org-tasks--state :initialized) t)
             (my/org-tasks--store))
           (my/org-tasks--queue (copy-tree (plist-get my/org-tasks--state :records)))))))
   (append `((maxResults . "100") (showCompleted . "true") (showHidden . "true")
             (showDeleted . "true") (showAssigned . "false")
             (fields . ,(concat "nextPageToken,items(" my/org-tasks--fields ")")))
           (when page (list (cons 'pageToken page))))))

(defun my/org-tasks--unlock-cycle ()
  (when my/org-tasks--lock
    (let ((directory my/org-tasks--lock))
      (setq my/org-tasks--lock nil)
      (when (file-exists-p (expand-file-name "pid" directory)) (delete-file (expand-file-name "pid" directory)))
      (ignore-errors (delete-directory directory)))))

(defun my/org-tasks--lock-cycle ()
  "Acquire the shared-state lock without taking over another instance's lock."
  (let ((lock (concat my/org-tasks--state-file ".lock")))
    (make-directory (file-name-directory lock) t)
    (condition-case nil (make-directory lock)
      (file-error (user-error "A Tasks sync lock exists; inspect its pid before removing it")))
    (setq my/org-tasks--lock lock)
    (set-file-modes lock #o700)
    (write-region (number-to-string (emacs-pid)) nil (expand-file-name "pid" lock) nil 'silent)
    (set-file-modes (expand-file-name "pid" lock) #o600)))

(defun my/org-tasks--finish (status)
  (my/org-tasks--unlock-cycle)
  (setq my/org-tasks--busy nil my/org-tasks--response nil)
  (when (equal status "up to date")
    (setq my/org-tasks--last-success (float-time)))
  (my/org-tasks--status status)
  (when (member status '("up to date" "needs attention"))
    (let ((my/org-tasks--refreshing t))
      (when (fboundp 'my/org-calendar-auto--refresh-agendas) (my/org-calendar-auto--refresh-agendas))
      (when (fboundp 'my/org-calendar-view-refresh-visible) (my/org-calendar-view-refresh-visible))))
  (when my/org-tasks--file (my/org-background-release my/org-tasks--file))
  (when my/org-tasks--rerun (setq my/org-tasks--rerun nil) (my/org-tasks--schedule)))

(defun my/org-tasks--start ()
  "Start one saved-buffer cycle, refreshing authorization silently if needed."
  (when my/org-tasks-mode
    (cond (my/org-tasks--busy (setq my/org-tasks--rerun t))
          ((not (my/org-tasks-session-ready-p))
           (my/org-tasks--status (if (or (memq my/org-tasks-auth-problem '(authorization unlock))
                                        (not (my/org-calendar-unlock-available-p))) "needs login" "pending"))
           (my/org-tasks-background-refresh))
          (t
           (condition-case problem
               (if (buffer-modified-p (my/org-tasks--buffer)) (my/org-tasks--status "pending")
                 (my/org-tasks--lock-cycle)
                 ;; Other Emacs instances may have advanced the shared private state.
                 (my/org-tasks--load-state)
                 (my/org-tasks--collect)
                 (setq my/org-tasks--busy t my/org-tasks--error nil
                       my/org-tasks--last-run (float-time))
                 (my/org-tasks--status "pending") (my/org-tasks--list))
             (user-error (setq my/org-tasks--error (error-message-string problem)) (my/org-tasks--finish "needs attention"))
             (error (setq my/org-tasks--error "Tasks sync could not start safely; no blind creation retries were made")
                    (my/org-tasks--finish "needs attention")))))))

(defun my/org-tasks--schedule (&rest _)
  (when (and my/org-tasks-mode (not my/org-tasks--saving) (not my/org-tasks--refreshing)
             (not (bound-and-true-p my/org-calendar-auto--refreshing)))
    (when (timerp my/org-tasks--debounce) (cancel-timer my/org-tasks--debounce))
    (setq my/org-tasks--debounce (run-at-time 2 nil #'my/org-tasks--start))))

(defun my/org-tasks--after-save ()
  (when (my/org-tasks--personal-buffer-p) (my/org-tasks--schedule)))

(defun my/org-tasks--agenda-open (&rest _)
  (when (derived-mode-p 'org-agenda-mode) (my/org-tasks--schedule)))

(defun my/org-tasks--agenda-edit (original &rest arguments)
  "Autosave a selected Personal task only if its source was clean before editing."
  (let* ((marker (org-get-at-bol 'org-hd-marker))
         (clean (and marker (marker-buffer marker)
                     (with-current-buffer (marker-buffer marker)
                       (and (my/org-tasks--personal-buffer-p) (not (buffer-modified-p))))))
         (result (apply original arguments)))
    (when clean (org-with-point-at marker (when (buffer-modified-p) (save-buffer))))
    result))

(defun my/org-tasks--auth-finished (success _background)
  (if success (my/org-tasks--schedule)
    (when my/org-tasks-mode
      (my/org-tasks--status (if (memq my/org-tasks-auth-problem '(authorization unlock)) "needs login" "pending")))))

(defun my/org-tasks-sync-now ()
  "Request a guarded sync, never using a manual bypass while paused."
  (interactive)
  (unless my/org-tasks-mode (user-error "Resume Personal Tasks sync first"))
  (my/org-tasks--start))

(define-minor-mode my/org-tasks-mode
  "Sync saved Personal tasks only, leaving old Google completions and Work alone."
  :global t :group 'org
  (if my/org-tasks-mode
      (if my/org-tasks--running (my/org-tasks--schedule)
        (condition-case problem
            (progn
              (my/org-calendar-prepare)
              (load my/org-tasks-settings-file nil t)
              (unless (and (stringp my/org-tasks-list-id) (not (string-empty-p my/org-tasks-list-id))
                           (not (equal my/org-tasks-list-id "@default"))
                           (equal my/org-tasks-account my/org-calendar-approved-primary-id)
                           (my/org-calendar-configured-id-p my/org-tasks-account))
                (user-error "Approve an exact Personal account and Tasks list in private settings"))
              (unless (equal my/org-tasks--scope (my/org-tasks--scope-id))
                (setq my/org-tasks--last-run nil my/org-tasks--last-success nil))
              (setq my/org-tasks--account (copy-sequence my/org-tasks-account)
                    my/org-tasks--list (copy-sequence my/org-tasks-list-id)
                    my/org-tasks--file (file-truename (my/org-file "personal.org"))
                    my/org-tasks--scope (my/org-tasks--scope-id)
                    my/org-tasks--state-file
                    (expand-file-name (concat "org-tasks-" my/org-tasks--scope ".json")
                                      (file-name-directory my/org-tasks-settings-file)))
              (my/org-tasks--load-state)
              (cl-incf my/org-tasks--generation)
              (setq my/org-tasks--running t)
              (add-hook 'after-save-hook #'my/org-tasks--after-save)
              (add-hook 'org-agenda-finalize-hook #'my/org-tasks--agenda-open t)
              (add-hook 'my/org-tasks-auth-finished-hook #'my/org-tasks--auth-finished)
              (dolist (command '(org-agenda-todo org-agenda-schedule org-agenda-deadline))
                (advice-add command :around #'my/org-tasks--agenda-edit))
              (setq my/org-tasks--timer (run-at-time 300 300 #'my/org-tasks--start))
              (my/org-tasks--schedule))
          (error (setq my/org-tasks-mode nil my/org-tasks--running nil
                       my/org-tasks--error (if (eq (car problem) 'user-error) (error-message-string problem)
                                            "Tasks settings or private cache could not be read safely"))
                 (my/org-tasks--status "needs attention") (signal (car problem) (cdr problem)))))
    (cl-incf my/org-tasks--generation)
    (setq my/org-tasks--running nil my/org-tasks--rerun nil)
    (dolist (timer (list my/org-tasks--timer my/org-tasks--debounce)) (when (timerp timer) (cancel-timer timer)))
    (setq my/org-tasks--timer nil my/org-tasks--debounce nil)
    (when my/org-tasks--response (ignore-errors (request-abort my/org-tasks--response)))
    (setq my/org-tasks--response nil my/org-tasks--busy nil)
    (my/org-tasks--unlock-cycle)
    (remove-hook 'after-save-hook #'my/org-tasks--after-save)
    (remove-hook 'org-agenda-finalize-hook #'my/org-tasks--agenda-open)
    (remove-hook 'my/org-tasks-auth-finished-hook #'my/org-tasks--auth-finished)
    (dolist (command '(org-agenda-todo org-agenda-schedule org-agenda-deadline))
      (advice-remove command #'my/org-tasks--agenda-edit))
    (my/org-tasks--status "paused")))

(defun my/org-tasks-resolve (key choice version remote etag &optional link-id)
  "Queue CHOICE for the exact saved version and Google version shown in review."
  (when my/org-tasks--busy (user-error "Wait for the current Tasks cycle before choosing"))
  (let* ((record (my/org-tasks--record key)) (marker (my/org-tasks--marker key))
         (local (my/org-tasks--local marker))
         (candidate (when link-id (seq-find (lambda (item) (equal link-id (plist-get item :id)))
                                            (plist-get record :candidates)))))
    (unless (and record (or (null marker) (not (buffer-modified-p (marker-buffer marker))))
                 (equal version (plist-get local :version))
                 (equal remote (if link-id (plist-get candidate :payload) (plist-get record :remote)))
                 (equal etag (if link-id (plist-get candidate :etag) (plist-get record :remote-etag))))
      (user-error "Task changed or has unsaved edits; save and reopen Tasks status"))
    (when (and (member choice '("delete" "restore" "retry" "link"))
               (not (yes-or-no-p
                     (pcase choice
                       ("delete" "Delete this one task in Google, keeping local notes and history? ")
                       ("restore" "Restore this task in Google with a new identity? ")
                       ("link" "Link this exact existing Google task without creating another? ")
                       (_ "Have you checked Google? Retrying a lost creation reply can create a duplicate. Retry? ")))))
      (user-error "Tasks action was not approved"))
    (unwind-protect
        (progn
          (my/org-tasks--lock-cycle)
          (my/org-tasks--load-state)
          (unless (equal record (my/org-tasks--record key))
            (user-error "Another Emacs instance changed Tasks; reopen status before choosing"))
          (my/org-tasks--put key :resolution
                             (list :choice choice :local-version version :remote remote :etag etag :link-id link-id))
          (my/org-tasks--store))
      (my/org-tasks--unlock-cycle))
    (my/org-tasks--schedule)
    (message "Tasks choice queued; newer edits will require another review")))

(defun my/org-tasks--button (label key choice version remote etag &optional id)
  (insert-text-button label 'follow-link t
                      'action (lambda (_button) (my/org-tasks-resolve key choice version remote etag id)))
  (insert "  "))

;;;###autoload
(defun my/org-tasks-review ()
  "Show Tasks status and explicit conflict/deletion/uncertain-creation choices."
  (interactive)
  (unless my/org-tasks--scope (user-error "Configure Personal Tasks sync first"))
  (let ((records (copy-tree (plist-get my/org-tasks--state :records))))
    (with-current-buffer (get-buffer-create "*Personal Tasks Sync*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Personal tasks: " my/org-tasks-status "\n"
                "Only personal.org and the approved Google list sync.\n"
                "Shared: title, scheduled day, completion. Notes and richer planning stay separate.\n\n")
        (when my/org-tasks--error (insert my/org-tasks--error "\n\n"))
        (dolist (record records)
          (when-let* ((issue (plist-get record :issue)))
            (let* ((key (plist-get record :key)) (local (plist-get record :last-local))
                   (remote (plist-get record :remote)) (version (plist-get record :local-version))
                   (etag (plist-get record :remote-etag)))
              (insert (or (plist-get local :title) (plist-get remote :title) "Task no longer in Personal") "\n" issue "\n")
              (dolist (item (list (cons "Org" local) (cons "Google" remote)))
                (insert (format "  %s: %s\n" (car item)
                                (if (plist-get (cdr item) :deleted) "deleted"
                                  (if (null (cdr item)) "not available"
                                    (format "%s | day: %s | %s" (plist-get (cdr item) :title)
                                            (or (plist-get (cdr item) :day) "undated")
                                            (plist-get (cdr item) :status)))))))
              (cond
               ((plist-get record :creating)
                (dolist (candidate (plist-get record :candidates))
                  (my/org-tasks--button "Link matching Google task" key "link" version
                                       (plist-get candidate :payload) (plist-get candidate :etag) (plist-get candidate :id)))
                (my/org-tasks--button "Checked Google; retry creation" key "retry" version remote etag))
               ((null local)
                (my/org-tasks--button "Keep Google; stop syncing this task" key "detach" version remote etag)
                (when (and remote (not (plist-get remote :deleted)))
                  (my/org-tasks--button "Delete Google task" key "delete" version remote etag)))
               ((plist-get remote :deleted)
                (my/org-tasks--button "Accept Google deletion" key "google" version remote etag)
                (unless (equal (plist-get local :status) "cancelled")
                  (my/org-tasks--button "Restore as new Google task" key "restore" version remote etag)))
               ((equal (plist-get local :status) "cancelled")
                (my/org-tasks--button "Keep Google task" key "google" version remote etag)
                (my/org-tasks--button "Confirm Google deletion" key "delete" version remote etag))
               (t (my/org-tasks--button "Keep Org" key "org" version remote etag)
                  (my/org-tasks--button "Use Google" key "google" version remote etag)))
              (insert "\n\n"))))
        (insert "Integrations (SPC n i) offers sync, pause/resume, and authorization.\n"
                "Deleting/refiling an Org heading alone never deletes Google.\n"
                "Historical Google completions were left out; linked completions still sync.\n"))
      (special-mode))
    (display-buffer "*Personal Tasks Sync*")))

(defvar my/org-tasks-status-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'my/org-tasks-status-open)
    (define-key map [mode-line mouse-3] #'my/org-tasks-status-menu)
    map))

(defun my/org-tasks-status-open (event)
  (interactive "e")
  (let ((window (posn-window (event-start event)))) (when (window-live-p window) (select-window window)))
  (my/org-tasks-review))

(defun my/org-tasks-status-menu (event)
  (interactive "e")
  (let ((map (make-sparse-keymap "Personal tasks")))
    (define-key map [status] '(menu-item "Status..." my/org-tasks-review))
    (define-key map [setup] '(menu-item "Google authorization..." my/org-tasks-setup))
    (define-key map [sync] `(menu-item "Sync now" my/org-tasks-sync-now :enable ,my/org-tasks-mode))
    (define-key map [pause] `(menu-item ,(if my/org-tasks-mode "Pause task sync" "Resume task sync") my/org-tasks-mode))
    (popup-menu map event)))

(defun my/org-tasks-status-render ()
  "Show one clickable Tasks icon in task context, or anywhere with a problem."
  (when (and my/org-tasks--scope
             (or (derived-mode-p 'org-agenda-mode 'org-timegrid-mode)
                 (my/org-tasks--personal-buffer-p)
                 (member (buffer-name) '("*Personal Tasks Sync*" "*Personal Tasks Setup*"))
                 (member my/org-tasks-status '("needs login" "needs attention")) my/org-tasks--error))
    (let* ((status (if my/org-tasks-mode my/org-tasks-status "paused"))
           (spec (or (and (equal status "up to date") '("up to date" "nf-fa-tasks" "✓" success "Up to date"))
                     (assoc (if (and (equal status "pending") my/org-tasks--error) "retrying" status)
                            (bound-and-true-p my/org-calendar-status-icons))))
           (icon (if (and spec (fboundp 'my/org-calendar-status-icon)) (my/org-calendar-status-icon spec)
                   (propertize "T" 'face 'shadow))))
      (propertize (concat " " icon " ") 'local-map my/org-tasks-status-map 'mouse-face 'mode-line-highlight
                  'help-echo (concat "Personal tasks: " status (when my/org-tasks--error (concat "\n" my/org-tasks--error))
                                     "\nSPC n i: Integrations\nLeft-click: Tasks details\nRight-click: Tasks controls")))))

(add-to-list 'global-mode-string '(:eval (my/org-tasks-status-render)))
(provide 'org-tasks-sync)
