;; -*- no-byte-compile: t; -*-
;;; $DOOMDIR/packages.el

;; To install a package:
;;   1. Declare it here with a `package!' statement,
;;   2. Run 'doom sync' in the shell,
;;   3. Restart Emacs.
;; Use 'C-h f package\!' to look up documentation for the `package!' macro.

;; org-appear and org-modern come from the `(org +pretty)' flag, which also
;; enables them. Declaring them here left org-modern installed but never turned
;; on, and unpinned.
(package! treemacs-all-the-icons)
(package! posframe)

;; No built-in Doom module for Groovy.
(package! groovy-mode)

;; ===== AI-assisted development =====
;; Provider-agnostic agent (Claude, Codex, Gemini, opencode...) over ACP. Renders
;; in a native Emacs buffer -- no terminal emulator, so no glyph/spinner issues.
(package! shell-maker)
(package! acp)
(package! agent-shell)
;; GUI Emacs (launched from Finder/dock) doesn't inherit the shell PATH, so it
;; can't find nvm-installed binaries like claude-agent-acp. This imports them.
(package! exec-path-from-shell)

;; Manages *live* shells only (project-grouped sidebar + posframe switcher with
;; preview). Calls no private agent-shell functions, so it survives upstream
;; churn. persp-mode and posframe are already provided by :ui workspaces above.
(package! agent-shell-hq
  :recipe (:host github :repo "SreenivasVRao/agent-shell-hq"))
;; Manages *past* sessions: ripgrep full-text search over transcripts, then
;; resume. Complements hq rather than overlapping it -- hq cannot see history.
(package! agent-recall)
