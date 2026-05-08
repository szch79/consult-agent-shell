;;; consult-agent-shell.el --- Consult commands to navigate agent-shell sessions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 MT Lin

;; Author: MT Lin <https://github.com/szch79>
;; Homepage: https://github.com/szch79/consult-agent-shell
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Package-Requires: ((emacs "29.1") (consult "3.4") (marginalia "2.2") (agent-shell "0.50.1"))

;;; Commentary:

;; Provides the command `consult-agent-shell'.

;;; Code:

(require 'cl-lib)
(require 'consult)
(require 'marginalia)
(require 'agent-shell)
(require 'agent-shell-usage)
(require 'agent-shell-viewport)


;;; Customization
;;;

(defgroup consult-agent-shell nil
  "Consult source for agent-shell sessions."
  :group 'consult)

(defcustom consult-agent-shell-annotation-fields '(agent usage state cwd)
  "Ordered list of fields shown by the marginalia annotator.

Each element is a symbol naming a field:

  `agent'  Agent name from the session's agent config.
  `usage'  Context-window usage.
  `state'  Session state (see `consult-agent-shell-state-labels').
  `cwd'    Working directory, abbreviated with `abbreviate-file-name'."
  :type '(repeat (choice (const agent) (const state)
                         (const cwd) (const usage)))
  :group 'consult-agent-shell)

(defcustom consult-agent-shell-state-labels
  '((thinking . "thinking")
    (action   . "action")
    (idle     . ""))
  "Strings rendered by the `state' annotation field.
`action' means action required, and it takes priority over `thinking' when both
are true."
  :type '(alist :key-type symbol :value-type string)
  :group 'consult-agent-shell)

(defcustom consult-agent-shell-title-max-width 50
  "Maximum display width for chat titles in the consult prompt.
Titles longer than this are truncated with an ellipsis, whitespace runs
(including newlines) collapse to single spaces."
  :type 'natnum
  :group 'consult-agent-shell)


;;; Marginalia fields
;;;

(defun consult-agent-shell--awaiting-permission-p (state)
  (cl-some (lambda (entry)
             (alist-get :permission-request-id (cdr entry)))
           (alist-get :tool-calls state)))

(defun consult-agent-shell--field-state (shell-buffer)
  (let ((state (buffer-local-value 'agent-shell--state shell-buffer)))
    (alist-get
     (cond ((consult-agent-shell--awaiting-permission-p state) 'action)
           ((agent-shell--active-requests-p state)             'thinking)
           (t                                                  'idle))
     consult-agent-shell-state-labels)))

(defun consult-agent-shell--field-cwd (shell-buffer)
  (abbreviate-file-name
   (directory-file-name
    (buffer-local-value 'default-directory shell-buffer))))

(defun consult-agent-shell--field-usage (shell-buffer)
  (let* ((state (buffer-local-value 'agent-shell--state shell-buffer))
         (usage (alist-get :usage state))
         (used  (or (alist-get :context-used usage) 0))
         (size  (or (alist-get :context-size usage) 0)))
    (if (> size 0)
        (let ((pct (/ (* 100.0 used) size)))
          (propertize (format "%s/%s (%.0f%%)"
                              (agent-shell--format-number-compact used)
                              (agent-shell--format-number-compact size)
                              pct)
                      'face (agent-shell--context-usage-face pct)))
      "")))

(defun consult-agent-shell--field-agent (shell-buffer)
  (or (thread-last (buffer-local-value 'agent-shell--state shell-buffer)
                   (alist-get :agent-config)
                   (alist-get :buffer-name))
      ""))

(defvar consult-agent-shell--field-specs
  '((state . (:renderer consult-agent-shell--field-state
              :face     marginalia-modified  :width 9))
    (usage . (:renderer consult-agent-shell--field-usage
              :face     nil                  :width 16))
    (agent . (:renderer consult-agent-shell--field-agent
              :face     marginalia-documentation :width 12))
    (cwd   . (:renderer consult-agent-shell--field-cwd
              :face     marginalia-file-name :width 30))))

(defun consult-agent-shell--shell-buffer-of (buffer)
  "Resolve BUFFER (shell or viewport) to its underlying shell buffer."
  (with-current-buffer buffer
    (cond ((derived-mode-p 'agent-shell-mode) buffer)
          ((or (derived-mode-p 'agent-shell-viewport-view-mode)
               (derived-mode-p 'agent-shell-viewport-edit-mode))
           (agent-shell-viewport--shell-buffer buffer))
          (t buffer))))

(defun consult-agent-shell--annotate (cand)
  "Marginalia annotator for category `agent-shell-session'.
CAND is the cdr of the `multi-category' candidate — the target buffer."
  (when-let* ((target (if (bufferp cand) cand (get-buffer cand)))
              ((buffer-live-p target))
              (shell  (consult-agent-shell--shell-buffer-of target)))
    (let ((parts
           (cl-loop
            for field in consult-agent-shell-annotation-fields
            for spec = (alist-get field consult-agent-shell--field-specs)
            when spec collect
            (let* ((str  (funcall (plist-get spec :renderer) shell))
                   (str  (truncate-string-to-width
                          str (plist-get spec :width) 0 ?\s))
                   (face (plist-get spec :face)))
              (if face (propertize str 'face face) str)))))
      (concat #(" " 0 1 (marginalia--align t))
              (mapconcat #'identity parts marginalia-separator)))))

(add-to-list 'marginalia-annotators
             '(agent-shell-session consult-agent-shell--annotate
                                   builtin none))


;;; Display name, target buffer, items
;;;

(defun consult-agent-shell--display-name (shell-buffer)
  (let* ((title (alist-get :title
                           (alist-get :session
                                      (buffer-local-value 'agent-shell--state
                                                          shell-buffer))))
         (raw (if (and title (not (string-empty-p title)))
                  title
                (buffer-name shell-buffer))))
    (truncate-string-to-width
     (replace-regexp-in-string "[ \t\n\r]+" " " raw)
     consult-agent-shell-title-max-width nil nil "…")))

(defun consult-agent-shell--target-buffer (shell-buffer)
  (or (agent-shell-viewport--buffer
       :shell-buffer shell-buffer :existing-only t)
      shell-buffer))

(defun consult-agent-shell--items ()
  (cl-loop for sb in (agent-shell-buffers)
           for n from 0
           ;; NOTE: sessions may have identical titles, so we need to make them
           ;; unique via `consult--tofu-encode', or they will be dedup'ed.
           collect (cons (concat (consult-agent-shell--display-name sb)
                                 (consult--tofu-encode n))
                         (consult-agent-shell--target-buffer sb))))


;;; Main
;;;

(defvar consult-agent-shell--source
  `(:name     "Agent Shell Sessions"
    :narrow   ?a
    :category agent-shell-session
    :face     consult-buffer
    :history  buffer-name-history
    :state    ,#'consult--buffer-state
    :items    ,#'consult-agent-shell--items)
  "Source for active agent-shell sessions.
Add to `consult-buffer-sources' for `consult-buffer' integration:
  (add-to-list \\='consult-buffer-sources \\='consult-agent-shell--source t)")

;;;###autoload
(defun consult-agent-shell ()
  "Switch to an active agent-shell session with `consult-buffer'."
  (interactive)
  (unless (agent-shell-buffers)
    (user-error "No active agent-shell sessions"))
  (consult-buffer (list consult-agent-shell--source)))

(provide 'consult-agent-shell)

;;; consult-agent-shell.el ends here
