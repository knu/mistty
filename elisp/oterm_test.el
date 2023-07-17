;;; Tests oterm.el -*- lexical-binding: t -*-

(require 'oterm)
(require 'ert)
(require 'ert-x)

(defmacro with-oterm-buffer (&rest body)
  `(ert-with-test-buffer ()
     (oterm--exec "bash" "--noprofile" "--norc")
     (while (eq (point-min) (point-max))
       (accept-process-output oterm-term-proc 0 100 t))
     (oterm-send-raw-string "PS1='$ '\n")
     (oterm-wait-for-output)
     (narrow-to-region (- (point) 2) (point-max))
     ,@body))

(defmacro with-oterm-buffer-selected (&rest body)
  `(save-window-excursion
     (with-oterm-buffer
      (with-selected-window (display-buffer (current-buffer))
        ,@body))))
  
(defun oterm-wait-for-output ()
  (unless (accept-process-output oterm-term-proc 0 500 t)
    (error "no output"))
  (while (accept-process-output oterm-term-proc 0 0 t)))

(defun oterm-test-content  (&optional nopointers)
  (interactive)
  (let ((output (buffer-substring-no-properties (point-min) (point-max)))
        (p (- (point) (point-min)))
        (pmark (- (oterm--work-pmark) (point-min))))
    (unless nopointers 
      (setq output
            (cond 
             ((= p pmark)
              (concat (substring output 0 p) "<>" (substring output p)))
             ((> p pmark)
              (concat (substring output 0 pmark) "<pmark>" (substring output pmark p) "<>" (substring output p)))
             ((< p pmark)
              (concat (substring output 0 p) "<>" (substring output p pmark) "<pmark>" (substring output pmark))))))
    (setq output (replace-regexp-in-string "\\$ \\(<>\\)?\n?$" "" output))
    (setq output (replace-regexp-in-string "[ \t]*$" "" output))
    output))

(ert-deftest test-oterm-simple-command ()
  (with-oterm-buffer
   (oterm-send-raw-string "echo hello\n")
   (oterm-wait-for-output)
   (should (equal "$ echo hello\nhello\n" (oterm-test-content)))))

(ert-deftest test-oterm-keystrokes ()
  (with-oterm-buffer-selected
   (should (equal 'oterm-self-insert-command (key-binding (kbd "e"))))
   (execute-kbd-macro (kbd "e c h o SPC o k RET"))
   (oterm-wait-for-output)
   (should (equal "$ echo ok\nok\n" (oterm-test-content)))))

(ert-deftest test-oterm-kill-term-buffer ()
  (let* ((buffer-and-proc (with-oterm-buffer
                           (cons oterm-term-buffer oterm-term-proc)))
         (term-buffer (car buffer-and-proc))
         (term-proc (cdr buffer-and-proc)))
    (should (not (buffer-live-p term-buffer)))
    (should (not (process-live-p term-proc)))))

(ert-deftest test-oterm-term-buffer-exits ()
  (with-oterm-buffer
   (oterm-send-raw-string "exit\n")
   (let ((tstart (current-time)))
     (while (or (process-live-p oterm-term-proc) (buffer-live-p oterm-term-buffer))
       (accept-process-output nil 0 10)
       (when (> (float-time (time-subtract (current-time) tstart)) 2)
         (error "process didn't end"))))
   (should (string-suffix-p "finished\n" (buffer-substring-no-properties (point-min) (point-max))))))
