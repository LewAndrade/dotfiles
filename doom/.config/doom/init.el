;;; init.el -*- lexical-binding: t; -*-

;; This file controls what Doom modules are enabled and what order they load
;; in. Remember to run 'doom sync' after modifying it!
;;
;; 'SPC h d h' (or 'C-h d h') opens Doom's documentation and module index.
;; Press 'K' on a module or flag to view its docs; 'gd' to browse its source.

(doom! :input
       ;;bidi
       ;;chinese
       ;;japanese
       ;;layout

       :completion
       (corfu +icons +orderless)  ; complete with cap(f), cape and a flying feather!
       vertico           ; the search engine of the future

       :ui
       doom              ; what makes DOOM look the way it does
       dashboard         ; a nifty splash screen for Emacs
       hl-todo           ; highlight TODO/FIXME/NOTE/DEPRECATED/HACK/REVIEW
       ligatures         ; ligatures and symbols to make your code pretty again
       (modeline +lights) ; snazzy, Atom-inspired modeline, plus API
       ophints           ; highlight the region an operation acts on
       (popup +all +defaults) ; tame sudden yet inevitable temporary windows
       smooth-scroll     ; So smooth you won't believe it's not butter
       (treemacs +lsp)   ; a project drawer, like neotree but cooler
       (vc-gutter +pretty) ; vcs diff in the fringe
       vi-tilde-fringe   ; fringe tildes to mark beyond EOB
       workspaces        ; tab emulation, persistence & separate workspaces

       :editor
       (evil +everywhere); come to the dark side, we have cookies
       file-templates    ; auto-snippets for empty files
       fold              ; (nigh) universal code folding
       format            ; automated prettiness
       multiple-cursors  ; editing in many places at once
       snippets          ; my elves. They type so I don't have to
       (whitespace +guess +trim) ; a butler for your whitespace

       :emacs
       dired             ; making dired pretty [functional]
       undo              ; persistent, smarter undo for your inevitable mistakes
       vc                ; version-control and Emacs, sitting in a tree

       :term
       vterm             ; the best terminal emulation in Emacs

       :checkers
       syntax            ; tasing you for every semicolon you forget

       :tools
       (debugger +lsp)   ; stepping through code, to help you add bugs
       (eval +overlay)   ; run code, run (also, repls)
       lookup            ; navigate your code and its documentation
       lsp               ; M-x vscode
       magit             ; a git porcelain for Emacs
       pdf               ; pdf enhancements
       tree-sitter       ; syntax and parsing, sitting in a tree...

       :os
       (:if (featurep :system 'macos) macos)  ; improve compatibility with macOS

       :lang
       emacs-lisp        ; drown in parentheses
       (java +lsp +tree-sitter)         ; the poster child for carpal tunnel syndrome
       (javascript +lsp +tree-sitter)   ; all(hope(abandon(ye(who(enter(here))))))
       json              ; At least it ain't XML
       (kotlin +lsp +tree-sitter)       ; a better, slicker Java(Script)
       markdown          ; writing docs for people to ignore
       (org +dragndrop)             ; organize your plain life in plain text
       (python +lsp +tree-sitter)       ; beautiful is better than ugly
       (sh +fish +lsp)   ; she sells {ba,z,fi}sh shells on the C xor
       (web +lsp)        ; the tubes
       yaml              ; JSON, but readable

       :config
       literate          ; config.org is the source of truth for config.el
       (default +bindings +smartparens))
