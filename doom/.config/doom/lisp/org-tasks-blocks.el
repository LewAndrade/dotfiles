;;; org-tasks-blocks.el --- One Org row for a task and its confirmed time block -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'json)
(require 'org)
(require 'org-agenda)
(require 'parse-time)
(require 'button)
(declare-function my/org-file "config" (name))
(declare-function my/org-tasks--check-scope "org-tasks-sync" ())
(declare-function my/org-tasks--record "org-tasks-sync" (key))
(declare-function my/org-calendar-auto--local-payload "org-calendar-auto" ())
(declare-function my/org-calendar-auto--hash "org-calendar-auto" (payload))
(declare-function my/org-calendar-view-refresh-visible "org-calendar-view" (&rest args))
(defvar my/org-tasks--scope)
(defvar my/org-tasks--file)
(defvar my/org-tasks--state-file)
(defvar my/org-tasks--account)
(defvar my/org-tasks--busy)
(defvar my/org-tasks--refreshing)
(defvar my/org-calendar-approved-primary-id)
(defvar my/org-calendar-auto--calendar)
(defvar my/org-calendar-auto--file)
(defvar my/org-calendar-auto--remote-table)
(defvar my/org-calendar-auto--busy)
(defvar my/org-calendar-auto--refreshing)
(defvar my/org-tasks-block--rendering nil)
(defvar my/org-tasks-block--problem nil)
(defvar my/org-tasks-block-mode nil)

(defun my/org-tasks-block--scope ()
  "Pin local links to the approved account, list, and two distinct source files."
  (my/org-tasks--check-scope)
  (unless (and (equal my/org-calendar-auto--calendar my/org-calendar-approved-primary-id)
               (equal my/org-tasks--account my/org-calendar-auto--calendar)
               (equal (file-truename my/org-calendar-auto--file)
                      (file-truename (my/org-file "calendar-personal.org"))))
    (user-error "Task/block links need the approved Personal Calendar mapping"))
  (secure-hash 'sha256 (json-encode (vector my/org-tasks--scope my/org-calendar-auto--calendar
                                          (file-truename my/org-calendar-auto--file)))))

(defun my/org-tasks-block--file ()
  (expand-file-name (concat "org-task-blocks-" (my/org-tasks-block--scope) ".json")
                    (file-name-directory my/org-tasks--state-file)))

(defun my/org-tasks-block--read ()
  "Read only confirmed identities; corrupt or cross-scope data never hides rows."
  (let* ((scope (my/org-tasks-block--scope)) (file (my/org-tasks-block--file))
         (data (when (file-exists-p file)
                 (with-temp-buffer
                   (insert-file-contents file)
                   (json-parse-buffer :object-type 'plist :array-type 'list :null-object nil))))
         (links (plist-get data :links)) keys tasks blocks)
    (when (and data (not (and (equal (plist-get data :version) 1)
                              (equal (plist-get data :scope) scope) (listp links))))
      (user-error "Invalid private task/block links; both sources remain visible"))
    (dolist (link links)
      (let ((key (plist-get link :key)) (task (plist-get link :task-id)) (block (plist-get link :event-id)))
        (unless (and (stringp key) (stringp task) (stringp block)
                     (equal (plist-get link :type) "focusTime")
                     (not (member key keys)) (not (member task tasks)) (not (member block blocks)))
          (user-error "Duplicate or invalid task/block identities; both sources remain visible"))
        (push key keys) (push task tasks) (push block blocks)))
    links))

(defun my/org-tasks-block--links ()
  "Fail open during rendering, with an explanation in Tasks status."
  (condition-case problem
      (prog1 (my/org-tasks-block--read) (setq my/org-tasks-block--problem nil))
    (error (setq my/org-tasks-block--problem (error-message-string problem)) nil)))

(defun my/org-tasks-block--change (change)
  "Atomically change private links only, never an Org file or Google object."
  (let* ((file (my/org-tasks-block--file)) (lock (concat file ".lock")) owned temporary)
    (unwind-protect
        (progn
          (make-directory (file-name-directory file) t)
          (set-file-modes (file-name-directory file) #o700)
          (condition-case nil (make-directory lock)
            (file-error (user-error "A task/block link lock exists; inspect its pid before removing it")))
          (setq owned t)
          (set-file-modes lock #o700)
          (write-region (number-to-string (emacs-pid)) nil (expand-file-name "pid" lock) nil 'silent)
          (set-file-modes (expand-file-name "pid" lock) #o600)
          (let ((links (funcall change (my/org-tasks-block--read))))
            (setq temporary (make-temp-file (concat file ".new-")))
            (set-file-modes temporary #o600)
            (write-region (json-encode (list :version 1 :scope (my/org-tasks-block--scope)
                                             :links (vconcat links))) nil temporary nil 'silent)
            (rename-file temporary file t)))
      (when (and temporary (file-exists-p temporary)) (delete-file temporary))
      (when owned
        (when (file-exists-p (expand-file-name "pid" lock)) (delete-file (expand-file-name "pid" lock)))
        (delete-directory lock)))))

(defun my/org-tasks-block--buffer (file)
  "Read sources without prompting to reload external or unsaved edits."
  (let ((buffer (or (get-file-buffer file) (find-file-noselect file))))
    (unless (verify-visited-file-modtime buffer)
      (user-error "A task/block source changed on disk; review it before linking"))
    buffer))

(defun my/org-tasks-block--sources (kind)
  "Collect unique Personal KIND identities, preserving point and source contents."
  (let ((file (if (eq kind 'task) my/org-tasks--file my/org-calendar-auto--file)) items)
    (with-current-buffer (my/org-tasks-block--buffer file)
      (org-with-wide-buffer
       (save-excursion
         (org-map-entries
          (lambda ()
            (when (equal (org-get-category) "Personal")
              (let* ((key (org-entry-get nil "GTASK_KEY"))
                     (id (if (eq kind 'task) (org-entry-get nil "GTASK_ID") (org-entry-get nil "GCAL_AUTO_ID")))
                     (state (org-get-todo-state)))
                (when (and id (if (eq kind 'task)
                                 (and key (equal id (plist-get (my/org-tasks--record key) :id))
                                      (member state '("TODO" "DOING" "WAIT" "DONE" "CANCELLED")))
                               (and (null state)
                                    (equal (org-entry-get nil "calendar-id") my/org-calendar-auto--calendar)
                                    (equal (org-entry-get nil "entry-id") (concat id "/" my/org-calendar-auto--calendar)))))
                  (push (list :key key :id id :marker (point-marker) :state state
                              :title (substring-no-properties (org-get-heading t t t t))
                              :scheduled (org-entry-get nil "SCHEDULED")
                              :schedule-marker
                              (when-let* ((stamp (org-element-property :scheduled (org-element-at-point))))
                                (copy-marker (org-element-property :begin stamp) t))
                              :version (secure-hash 'sha256
                                                    (buffer-substring-no-properties
                                                     (point) (save-excursion (org-end-of-subtree t t) (point))))) items)))))
          nil 'file))))
    (nreverse items)))

(defun my/org-tasks-block--unique (items field value)
  (let ((matches (seq-filter (lambda (item) (equal (plist-get item field) value)) items)))
    (when (= (length matches) 1) (car matches))))

(defun my/org-tasks-block--pair (link tasks blocks &optional approving)
  "Resolve exact identities; keep independent or unsupported plans separate."
  (let* ((task (my/org-tasks-block--unique tasks :key (plist-get link :key)))
         (block (my/org-tasks-block--unique blocks :id (plist-get link :event-id)))
         (remote (and (hash-table-p my/org-calendar-auto--remote-table)
                      (gethash (plist-get link :event-id) my/org-calendar-auto--remote-table)))
         reason payload start end scheduled stamp)
    (condition-case nil
        (cond
         ((not (and task block (equal (plist-get task :id) (plist-get link :task-id))
                    (my/org-tasks-block--unique tasks :id (plist-get link :task-id))))
          (setq reason "A linked identity is missing, duplicated, or restored with a new ID"))
         ((or (and approving (not (equal (plist-get remote :eventType) "focusTime")))
              (and remote (or (equal (plist-get remote :status) "cancelled")
                              (and (plist-get remote :eventType)
                                   (not (equal (plist-get remote :eventType) "focusTime"))))))
          (setq reason "The Calendar source is not a confirmed focus-time block"))
         (t
          (org-with-point-at (plist-get block :marker)
            (setq payload (my/org-calendar-auto--local-payload))
            (when (or (org-entry-get nil "GCAL_AUTO_CONFLICT") (org-entry-get nil "GCAL_AUTO_RECURRING")
                      (org-entry-get nil "GCAL_AUTO_SERIES")
                      (not (equal (org-entry-get nil "GCAL_AUTO_BASE") (my/org-calendar-auto--hash payload))))
              (setq reason "The Calendar block has pending edits, a conflict, or recurrence")))
          (unless reason
            (setq start (parse-iso8601-time-string (alist-get 'dateTime (alist-get 'start payload)))
                  end (parse-iso8601-time-string (alist-get 'dateTime (alist-get 'end payload)))
                  scheduled (plist-get task :scheduled))
            (cond
             ((or (not (time-less-p start end))
                  (not (equal (format-time-string "%F" start) (format-time-string "%F" end))))
              (setq reason "Only single-day time blocks can be combined safely"))
             ((not (and scheduled (equal (substring scheduled 1 11) (format-time-string "%F" start))))
              (setq reason "The task's scheduled day and the block's day differ"))
             ((string-match-p "[0-9][0-9]:[0-9][0-9]\\|[.+]\\{1,2\\}[0-9]+[hdwmy]" scheduled)
              (setq reason "The task has its own local time or repeater; both plans remain visible"))
             (t (setq stamp (concat (format-time-string "<%Y-%m-%d %a %H:%M" start)
                                    (format-time-string "-%H:%M>" end))))))))
      (error (setq reason "The source versions could not be read safely")))
    (list :link link :task task :block block :start start :end end :stamp stamp :reason reason)))

(defun my/org-tasks-block--pairs ()
  (when-let* ((links (my/org-tasks-block--links)))
    (condition-case problem
        (let ((tasks (my/org-tasks-block--sources 'task)) (blocks (my/org-tasks-block--sources 'block)))
          (mapcar (lambda (link) (my/org-tasks-block--pair link tasks blocks)) links))
      (error (setq my/org-tasks-block--problem (error-message-string problem)) nil))))

(defun my/org-tasks-block--refresh ()
  "Redraw views without scheduling sync, moving sources, or making network calls."
  (let ((my/org-tasks--refreshing t) (my/org-calendar-auto--refreshing t))
    (when (fboundp 'my/org-calendar-auto--refresh-agendas) (my/org-calendar-auto--refresh-agendas))
    (when (fboundp 'my/org-calendar-view-refresh-visible) (my/org-calendar-view-refresh-visible))))

(defun my/org-tasks-block--link (key id)
  "Confirm KEY and ID locally; caller has obtained approval for this exact pair."
  (when (or my/org-tasks--busy my/org-calendar-auto--busy) (user-error "Wait for Google sync before linking"))
  (let* ((tasks (my/org-tasks-block--sources 'task)) (blocks (my/org-tasks-block--sources 'block))
         (task (my/org-tasks-block--unique tasks :key key))
         (link (list :key key :task-id (plist-get task :id) :event-id id :type "focusTime"))
         (pair (my/org-tasks-block--pair link tasks blocks t)))
    (when (plist-get pair :reason) (user-error "%s" (plist-get pair :reason)))
    (dolist (source (list (plist-get pair :task) (plist-get pair :block)))
      (when (buffer-modified-p (marker-buffer (plist-get source :marker)))
        (user-error "Save task/block source edits before confirming a link")))
    (my/org-tasks-block--change
     (lambda (links)
       (when (seq-some (lambda (old) (or (equal key (plist-get old :key)) (equal id (plist-get old :event-id)))) links)
         (user-error "A task or block is already linked; unlink it before choosing another"))
       (cons link links)))
    (my/org-tasks-block--refresh)))

(defun my/org-tasks-block--source-marker ()
  (if (derived-mode-p 'org-agenda-mode) (org-get-at-bol 'org-hd-marker)
    (when (derived-mode-p 'org-mode) (save-excursion (org-back-to-heading t) (point-marker)))))

(defun my/org-tasks-block--select (prompt sources)
  "Use titles for selection only, never for automatic identity matching."
  (unless sources (user-error "No synced Personal source is available for this selection"))
  (let* ((options (mapcar (lambda (source)
                           (cons (format "%s [%s, line %d]" (plist-get source :title) (plist-get source :id)
                                         (org-with-point-at (plist-get source :marker) (line-number-at-pos))) source)) sources))
         (choice (completing-read prompt options nil t)))
    (cdr (assoc choice options))))

;;;###autoload
(defun my/org-tasks-block-link ()
  "Choose and confirm one task/block pair without changing either Google object."
  (interactive)
  (my/org-tasks-block--scope)
  (let* ((tasks (my/org-tasks-block--sources 'task))
         (blocks (seq-filter (lambda (block)
                                (equal (and (hash-table-p my/org-calendar-auto--remote-table)
                                            (plist-get (gethash (plist-get block :id) my/org-calendar-auto--remote-table) :eventType))
                                      "focusTime")) (my/org-tasks-block--sources 'block)))
         (marker (my/org-tasks-block--source-marker))
         (task (or (seq-find (lambda (item) (equal marker (plist-get item :marker))) tasks)
                   (my/org-tasks-block--select "Task to link: " tasks)))
         (block (or (seq-find (lambda (item) (equal marker (plist-get item :marker))) blocks)
                    (my/org-tasks-block--select "Calendar time block: " blocks)))
         (pair (my/org-tasks-block--pair
                (list :key (plist-get task :key) :task-id (plist-get task :id) :event-id (plist-get block :id)) tasks blocks t)))
    (when (plist-get pair :reason) (user-error "%s" (plist-get pair :reason)))
    (unless (yes-or-no-p (format "Show task %s using block %s (%s), with no Google changes? "
                                (plist-get task :title) (plist-get block :title) (plist-get pair :stamp)))
      (user-error "No task/block link was saved"))
    ;; A minibuffer confirmation can allow sync or another editor to change sources.
    (dolist (old (list task block))
      (unless (equal (plist-get old :version)
                     (plist-get (my/org-tasks-block--unique (my/org-tasks-block--sources
                                                           (if (eq old task) 'task 'block)) :id (plist-get old :id)) :version))
        (user-error "A source changed while choosing; review the current pair")))
    (my/org-tasks-block--link (plist-get task :key) (plist-get block :id))
    (message "Local task/block link saved; no task, event, or schedule was changed")))

;;;###autoload
(defun my/org-tasks-block-unlink (&optional key expected-link)
  "Restore separate displays without changing sources or Google.
When supplied, EXPECTED-LINK must still match KEY under the cache lock."
  (interactive)
  (unless key
    (let ((marker (my/org-tasks-block--source-marker)))
      (setq key (when marker (org-with-point-at marker (org-entry-get nil "GTASK_KEY"))))))
  (unless key
    (let* ((links (my/org-tasks-block--read))
           (choices (mapcar (lambda (link) (cons (format "%s / %s" (plist-get link :key) (plist-get link :event-id)) link)) links)))
      (setq key (plist-get (cdr (assoc (completing-read "Unlink task/block: " choices nil t) choices)) :key))))
  (my/org-tasks-block--change
   (lambda (links)
     (when (and expected-link
                (not (equal expected-link (seq-find (lambda (link) (equal key (plist-get link :key))) links))))
       (user-error "The link changed while choosing; reopen the picker"))
     (seq-remove (lambda (link) (equal key (plist-get link :key))) links)))
  (my/org-tasks-block--refresh)
  (message "Local task/block link removed; both sources are unchanged"))

;;;###autoload
(defun my/org-tasks-block-visit (&optional key)
  "Visit KEY's Calendar source, or the current task row's block if KEY is nil."
  (interactive)
  (let* ((marker (unless key (my/org-tasks-block--source-marker)))
         (pair (seq-find (lambda (item)
                           (if key (equal key (plist-get (plist-get item :link) :key))
                             (equal marker (plist-get (plist-get item :task) :marker))))
                         (my/org-tasks-block--pairs)))
         (block (plist-get (plist-get pair :block) :marker)))
    (unless (and block (marker-buffer block)) (user-error "This task has no available linked block"))
    (pop-to-buffer (marker-buffer block)) (goto-char block) (org-fold-show-context)))

(defun my/org-tasks-block--agenda (original file date &rest args)
  "Project confirmed block times onto task rows, retaining actual source actions."
  (let ((ordinary (apply original file date args)))
    (if (or my/org-tasks-block--rendering (not my/org-tasks-block-mode)
            (not (and (stringp my/org-tasks--file) (stringp my/org-calendar-auto--file)))
            (not (member (file-truename file) (list my/org-tasks--file (file-truename my/org-calendar-auto--file))))) ordinary
      (let* ((pairs (seq-remove (lambda (pair)
                                 (or (plist-get pair :reason)
                                     (let ((marker (plist-get (plist-get pair :task) :marker)))
                                       (and (eq (marker-buffer marker) org-agenda-restrict)
                                            (or (< marker org-agenda-restrict-begin)
                                                (>= marker org-agenda-restrict-end))))))
                               (my/org-tasks-block--pairs)))
             (task-file (equal (file-truename file) my/org-tasks--file))
             (types (or args org-agenda-entry-types)) rendered)
        (if (not (and (or (memq :scheduled types) (memq :scheduled* types))
                      (member my/org-tasks--file (mapcar #'file-truename (org-agenda-files t))))) ordinary
          (if (not task-file)
            (seq-remove (lambda (line)
                          (seq-some (lambda (pair) (equal (get-text-property 0 'org-hd-marker line)
                                                         (plist-get (plist-get pair :block) :marker))) pairs)) ordinary)
          (if (not (or (memq :scheduled types) (memq :scheduled* types))) ordinary
            (dolist (pair pairs)
              (let* ((task (plist-get pair :task)) (marker (plist-get task :marker))
                     (state (plist-get task :state)) (key (plist-get task :key))
                     (my/org-tasks-block--rendering t) lines)
                (setq ordinary
                      (seq-remove (lambda (line) (and (equal marker (get-text-property 0 'org-hd-marker line))
                                                     (member (get-text-property 0 'type line)
                                                             '("scheduled" "past-scheduled")))) ordinary))
                (with-temp-buffer
                  ;; Clone the task so priority, tags, deadlines, and warnings stay native.
                  (insert "#+category: Personal\n"
                          (org-with-point-at marker
                            (buffer-substring-no-properties (point) (save-excursion (org-end-of-subtree t t) (point)))))
                  (let ((org-inhibit-startup t)) (delay-mode-hooks (org-mode)))
                  (goto-char (point-min)) (re-search-forward org-heading-regexp) (org-back-to-heading t)
                  (let ((org-inhibit-logging t) (inhibit-message t) (message-log-max nil))
                    (org-entry-put nil "SCHEDULED" (plist-get pair :stamp)))
                  (let ((render-buffer (current-buffer)) (buffer-file-name file))
                    (cl-letf (((symbol-function 'org-get-agenda-file-buffer) (lambda (&rest _) render-buffer)))
                      (setq lines (funcall original file date (if (memq :scheduled types) :scheduled :scheduled*)))))
                  (setq lines (seq-filter (lambda (line)
                                           (org-with-point-at (get-text-property 0 'org-hd-marker line)
                                             (equal key (org-entry-get nil "GTASK_KEY")))) lines))
                  (dolist (line lines)
                    (add-text-properties 0 (length line)
                                         (list 'org-hd-marker marker 'org-marker (plist-get task :schedule-marker)
                                               'todo-state state
                                               'my/org-task-block (plist-get pair :link)
                                               'help-echo "Task with a confirmed time block. RET visits the task; Integrations (SPC n i) offers Visit for the block.") line)))
                (setq rendered (append rendered lines))))
            (append ordinary rendered))))))))

(defun my/org-tasks-block--agenda-action (original &rest args)
  "Recheck the projection after a native task state or scheduling action."
  (let ((linked (org-get-at-bol 'my/org-task-block)) (marker (org-get-at-bol 'org-hd-marker)) (old-point (point))
        (result (apply original args)))
    (when linked
      (let ((my/org-tasks--refreshing t) (my/org-calendar-auto--refreshing t))
        (org-agenda-redo t))
      (goto-char (point-min))
      (while (and (not (eobp)) (not (equal marker (org-get-at-bol 'org-hd-marker)))) (forward-line))
      (when (eobp) (goto-char (min old-point (point-max)))))
    result))

(defun my/org-tasks-block--review (&rest _)
  "Explain confirmed and inactive links in the existing Tasks status buffer."
  (when-let* ((buffer (get-buffer "*Personal Tasks Sync*")))
    (let ((pairs (my/org-tasks-block--pairs)))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert "\nLocal time-block links (no Google changes)\n")
          (when my/org-tasks-block--problem (insert my/org-tasks-block--problem "\n"))
          (dolist (pair pairs)
            (let ((key (plist-get (plist-get pair :link) :key)))
              (insert (format "%s: %s\n" (or (plist-get (plist-get pair :task) :title) "Unavailable task")
                              (or (plist-get pair :reason) (plist-get pair :stamp))))
              (insert-text-button "Unlink locally" 'follow-link t
                                  'action (lambda (_button) (my/org-tasks-block-unlink key))) (insert "\n")))
          (insert "Integrations (SPC n i) offers Link, Unlink, and Visit for task/time-block pairs.\n"
                  "No title-based auto-merging. Unsupported or conflicting pairs remain separate.\n"))))))

(define-minor-mode my/org-tasks-block-mode
  "Display a task and its explicitly linked focus-time block as one Org task."
  :global t :group 'org
  (if my/org-tasks-block-mode
      (progn
        (advice-add 'org-agenda-get-day-entries :around #'my/org-tasks-block--agenda '((depth . 80)))
        (dolist (command '(org-agenda-todo org-agenda-schedule org-agenda-date-later))
          (advice-add command :around #'my/org-tasks-block--agenda-action '((depth . 80))))
        (advice-add 'my/org-tasks-review :after #'my/org-tasks-block--review))
    (advice-remove 'org-agenda-get-day-entries #'my/org-tasks-block--agenda)
    (dolist (command '(org-agenda-todo org-agenda-schedule org-agenda-date-later))
      (advice-remove command #'my/org-tasks-block--agenda-action))
    (advice-remove 'my/org-tasks-review #'my/org-tasks-block--review)))

(provide 'org-tasks-blocks)
