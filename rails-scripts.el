;;; rails-scripts.el --- emacs-rails integraions with rails script/* scripts

;; Copyright (C) 2006 Dmitry Galinsky <dima dot exe at gmail dot com>

;; Authors: Dmitry Galinsky <dima dot exe at gmail dot com>,
;;          Rezikov Peter <crazypit13 (at) gmail.com>

;; Keywords: ruby rails languages oop
;; $URL$
;; $Id$

;;; License

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation; either version 2
;; of the License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.

(eval-when-compile
  (require 'inf-ruby)
  (require 'ruby-mode))

(defvar rails-script:generators-list
  '("controller" "model" "scaffold" "migration" "plugin" "mailer" "observer" "resource"))

(defvar rails-script:destroy-list rails-script:generators-list)

(defvar rails-script:generate-params-list
  '("-f")
  "Add parameters to script/generate.
For example -s to keep existing files and -c to add new files into svn.")

(defvar rails-script:destroy-params-list
  '("-f")
  "Add parameters to script/destroy.
For example -c to remove files from svn.")

(defvar rails-script:buffer-name "*ROutput*")

(defvar rails-script:running-script-name nil
  "Currently running the script name")

(defvar rails-script:history (list))
(defvar rails-script:history-of-generate (list))
(defvar rails-script:history-of-destroy (list))

;; output-mode

(defconst rails-script:font-lock-ketwords
  (list
   '("^\\(\(in [^\)]+\)\\)$"               1 font-lock-builtin-face)
   '(" \\(rm\\|rmdir\\) "                  1 font-lock-warning-face)
   '(" \\(missing\\|notempty\\|exists\\) " 1 font-lock-warning-face)
   '(" \\(create\\|dependency\\) "         1 font-lock-function-name-face)))

(defconst rails-script:button-regexp
  " \\(create\\) + \\([^ ]+\\.\\w+\\)")

(defvar rails-script:output-mode-ret-value nil)
(defvar rails-script:after-hook-internal nil)

(defcustom rails-script:after-hook '(rails-script:popup-buffer rails-script:push-first-button)
  "Hooks ran after script ran."
  :group 'rails
  :type 'hook)

(defcustom rails-script:show-buffer-hook nil
  "Hooks ran when output buffer shown."
  :group 'rails
  :type 'hook)

(defun rails-script:make-buttons (start end len)
  (save-excursion
    (let ((buffer-read-only nil))
      (goto-char start)
      (while (re-search-forward rails-script:button-regexp end t)
        (make-button (match-beginning 2) (match-end 2)
                     :type 'rails-button
                     :rails:file-name (match-string 2))))))

(defun rails-script:popup-buffer (&optional do-not-scroll-to-top)
  "Popup output buffer."
  (unless (buffer-visible-p rails-script:buffer-name)
    (display-buffer rails-script:buffer-name t))
  (let ((win (get-buffer-window-list rails-script:buffer-name)))
    (when win
      (unless do-not-scroll-to-top
        (mapcar #'(lambda(w) (set-window-point w 0)) win))
      (run-hooks 'rails-script:show-buffer-hook))))

(defun rails-script:push-first-button ()
  (let (file-name)
    (with-current-buffer (get-buffer rails-script:buffer-name)
      (let ((button (next-button 1)))
        (when button
          (setq file-name (button-get button :rails:file-name)))))
    (when file-name
      (rails-core:find-file-if-exist file-name))))

(defun rails-script:toggle-output-window ()
  (interactive)
  (let ((current (current-buffer))
        (buf (get-buffer rails-script:buffer-name)))
    (if buf
        (if (buffer-visible-p rails-script:buffer-name)
            (delete-windows-on buf)
          (progn
            (pop-to-buffer rails-script:buffer-name t t)
            (pop-to-buffer current t t)
            (run-hooks 'rails-script:show-buffer-hook)))
      (message "No output window found. Try running a script or a rake task before."))))

(defun rails-script:setup-output-buffer ()
  "Setup default variables and values for the output buffer."
  (set (make-local-variable 'font-lock-keywords-only) t)
  (make-local-variable 'font-lock-defaults)
  (set (make-local-variable 'scroll-margin) 0)
  (set (make-local-variable 'scroll-preserve-screen-position) nil)
  (make-local-variable 'after-change-functions)
  (rails-minor-mode t))

(define-derived-mode rails-script:output-mode fundamental-mode "ROutput"
  "Major mode to Rails Script Output."
  (rails-script:setup-output-buffer)
  (setq font-lock-defaults '((rails-script:font-lock-ketwords) nil t))
  (buffer-disable-undo)
  (setq buffer-read-only t)
  (rails-script:make-buttons (point-min) (point-max) (point-max))
  (add-hook 'after-change-functions 'rails-script:make-buttons nil t)
  (run-hooks 'rails-script:output-mode-hook))

(defun rails-script:running-p ()
  (get-buffer-process rails-script:buffer-name))

(defun rails-script:kill-script ()
  "Kill the currently running rails script"
  (interactive)
  (let ((proc (rails-script:running-p)))
    (if proc
        (delete-process proc))))

(defun rails-script:sentinel-proc (proc msg)
  (let* ((name rails-script:running-script-name)
         (ret-val (process-exit-status proc))
         (buf (get-buffer rails-script:buffer-name))
         (ret-message (if (zerop ret-val) "successful" "failure")))
    (with-current-buffer buf
      (set (make-local-variable 'rails-script:output-mode-ret-value) ret-val))
    (when (memq (process-status proc) '(exit signal))
      (setq rails-script:running-script-name nil
            msg (format "%s was stopped (%s)." name ret-message)))
    (message (replace-regexp-in-string "\n" "" msg))
    (with-current-buffer buf
      (run-hooks 'rails-script:after-hook)
      (run-hooks 'rails-script:after-hook-internal))))

(defun rails-script:run (command parameters &optional buffer-major-mode mode-line-string)
  "Run a Rails script COMMAND with PARAMETERS with
BUFFER-MAJOR-MODE and process-sentinel SENTINEL."
  (unless (listp parameters)
    (error "rails-script:run PARAMETERS must be a list"))
  (rails-project:with-root
   (root)
   (save-some-buffers)
   (let ((proc (rails-script:running-p)))
     (if proc
         (message "Only one instance rails-script allowed")
       (let* ((default-directory root)
              (proc (rails-cmd-proxy:start-process rails-script:buffer-name
                                                   rails-script:buffer-name
                                                   command
                                                   (strings-join " " parameters))))
         (with-current-buffer (get-buffer rails-script:buffer-name)
           (let ((buffer-read-only nil)
                 (win (get-buffer-window-list rails-script:buffer-name)))
             (erase-buffer))
           (if buffer-major-mode
               (apply buffer-major-mode (list))
             (rails-script:output-mode))
           (add-hook 'after-change-functions 'rails-cmd-proxy:convert-buffer-from-remote nil t))
         (set-process-coding-system proc 'utf-8-dos 'utf-8-dos)
         (set-process-sentinel proc 'rails-script:sentinel-proc)
         (set-process-filter proc 'ansi-color-insertion-filter)
         (setq rails-script:running-script-name
               (strings-join " " (cons command parameters)))         
         (setq rails-ui:mode-line-script-name (or mode-line-string
                                                  command))
         (message "Starting %s." rails-script:running-script-name))))))

(defun rails-script:find-rails-command (command)
  "Find first of 'script/rails command', 'script/command' or 'rails command' as a list of program & args"
  (cond ((file-exists-p (rails-core:file "bin/rails"))
         (list rails-ruby-command (rails-core:file "bin/rails") command))
        ((file-exists-p (rails-core:file (format "bin/%s" command)))
         (list rails-ruby-command (rails-core:file (format "bin/%s" command))))
        (t (list "rails" command))))

(defun rails-script:run-rails-command (command &rest parameters)
  (let ((cmdlist (append (rails-script:find-rails-command command) parameters)))
    (rails-script:run (car cmdlist) (cdr cmdlist))))

;;;;;;;;;; Destroy stuff ;;;;;;;;;;

(defun rails-script:run-destroy (what &rest parameters)
  "Run the destroy script using WHAT and PARAMETERS."
  (apply #'rails-script:run-rails-command "destroy" what
         (append parameters rails-script:destroy-params-list)))

(defun rails-script:destroy (what)
  "Run destroy WHAT"
  (interactive (rails-completing-read "What destroy" rails-script:destroy-list
                                      'rails-script:history-of-destroy nil))
  (let ((name (intern (concat "rails-script:destroy-"
                              (replace-regexp-in-string "_" "-" what)))))
    (when (fboundp name)
      (call-interactively name))))

(defmacro rails-script:gen-destroy-function (name &optional completion completion-arg)
  (let ((func (intern (format "rails-script:destroy-%s" name)))
        (param (intern (concat name "-name"))))
    `(defun ,func (&optional ,param)
       (interactive
        (list (completing-read ,(concat "Destroy "
                                        (replace-regexp-in-string "[^a-z0-9]" " " name)
                                        ": ")
                               ,(if completion
                                    `(list->alist
                                      ,(if completion-arg
                                           `(,completion ,completion-arg)
                                         `(,completion)))
                                  nil))))
       (when (string-not-empty ,param)
         (rails-script:run-destroy ,(replace-regexp-in-string "-" "_" name) ,param)))))

(rails-script:gen-destroy-function "controller" rails-core:controllers t)
(rails-script:gen-destroy-function "model"      rails-core:models)
(rails-script:gen-destroy-function "scaffold")
(rails-script:gen-destroy-function "migration"  rails-core:migrations t)
(rails-script:gen-destroy-function "mailer"     rails-core:mailers)
(rails-script:gen-destroy-function "plugin"     rails-core:plugins)
(rails-script:gen-destroy-function "observer"   rails-core:observers)
(rails-script:gen-destroy-function "resource")

;;;;;;;;;; Generators stuff ;;;;;;;;;;

(defun rails-script:run-generate (what &rest parameters)
  "Run the generate script using WHAT and PARAMETERS."
  (apply #'rails-script:run-rails-command "generate" what
         (append parameters rails-script:generate-params-list)))

(defun rails-script:generate (what)
  "Run generate WHAT"
  (interactive (rails-completing-read "What generate" rails-script:generators-list
                                      'rails-script:history-of-generate nil))
  (let ((name (intern (concat "rails-script:generate-"
                              (replace-regexp-in-string "_" "-" what)))))
    (when (fboundp name)
      (call-interactively name))))

(defmacro rails-script:gen-generate-function (name &optional completion completion-arg)
  (let ((func (intern (format "rails-script:generate-%s" name)))
        (param (intern (concat name "-name"))))
    `(defun ,func (&optional ,param)
       (interactive
        (list (completing-read ,(concat "Generate "
                                        (replace-regexp-in-string "[^a-z0-9]" " " name)
                                        ": ")
                               ,(if completion
                                    `(list->alist
                                      ,(if completion-arg
                                           `(,completion ,completion-arg)
                                         `(,completion)))
                                  nil))))
       (when (string-not-empty ,param)
         (rails-script:run-generate ,(replace-regexp-in-string "-" "_" name) ,param)))))

(defun rails-script:generate-controller (&optional controller-name actions)
  "Generate a controller and open the controller file."
  (interactive (list
                (completing-read "Controller name (use autocomplete) : "
                                 (list->alist (rails-core:controllers-ancestors)))
                (read-string "Actions (or return to skip): ")))
  (when (string-not-empty controller-name)
    (rails-script:run-generate "controller" controller-name actions)))

(defun rails-script:generate-scaffold (&optional model-name controller-name actions)
  "Generate a scaffold and open the controller file."
  (interactive
   "MModel name: \nMController (or return to skip): \nMActions (or return to skip): ")
  (when (string-not-empty model-name)
    (if (string-not-empty controller-name)
        (rails-script:run-generate "scaffold" model-name controller-name actions)
      (rails-script:run-generate "scaffold" model-name))))

(rails-script:gen-generate-function "model"     rails-core:models-ancestors)
(rails-script:gen-generate-function "migration")
(rails-script:gen-generate-function "plugin")
(rails-script:gen-generate-function "mailer")
(rails-script:gen-generate-function "observer")
(rails-script:gen-generate-function "resource")

;;;;;;;;;; Rails create project ;;;;;;;;;;

(defun rails-script:create-project (dir)
  "Create a new project in a directory named DIR."
  (interactive "FNew Rails project directory: ")
  (make-directory dir t)
  (let ((default-directory (concat (expand-file-name dir) "/")))
    (flet ((rails-project:root () default-directory))
      (rails-script:run "rails" (list "--skip" (rails-project:root))))))

;;;;;;;;;; Shells ;;;;;;;;;;

(defun rails-script:run-interactive (name script &rest params)
  "Run an interactive shell with SCRIPT in a buffer named
*rails-<project-name>-<name>*."
  (rails-project:with-root
   (root)
   (let ((buffer-name (format "rails-%s-%s" (rails-project:name) name)))
     (apply #'run-ruby-in-buffer buffer-name script params)
     (setq ruby-buffer buffer-name))
   (rails-minor-mode t)))

(defun rails-script:console (&optional environment)
  "Run console. With prefix arg, prompts for environment."
  (interactive (list
                (and current-prefix-arg
                     (read-buffer "Environment: " rails-default-environment))))
  (let* ((environment (or environment rails-default-environment))
         (name (format "console at (%s)" environment))
         (buffer (get-buffer (format "*rails-%s-%s*" (rails-project:name) name))))
    (if buffer
        (progn
          (when (fboundp 'inf-ruby-mode) (setq inf-ruby-buffer buffer))
          (switch-to-buffer-other-window buffer))
      (rails-script:run-interactive name
                                    "console"
                                    environment))))

(defun rails-script:breakpointer ()
  "Run breakpointer."
  (interactive)
  (rails-script:run-interactive "breakpointer" "breakpointer"))

(provide 'rails-scripts)
