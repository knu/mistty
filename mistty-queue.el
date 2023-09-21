;;; mistty.el --- Queue of terminal actions for mistty.el. -*- lexical-binding: t -*-

;; This program is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 3 of the
;; License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see
;; `http://www.gnu.org/licenses/'.

;;; Code:

(eval-when-compile
  (require 'cl-lib))

;;; Commentary:
;;
;; This file defines the struct `mistty--queue' to be used in mistty.el.
;;
;; `mistty--queue' sends strings to the terminal process in sequence,
;; using a generator to adapt the next string to the current state of
;; the process.

(require 'generator)

(require 'mistty-log)
(require 'mistty-util)

(defvar mistty-timeout-s 0.5)
(defvar mistty-stable-delay-s 0.1)

;; A queue of strings to send to the terminal process.
;;
;; The queue contains a generator, which yields the strings to send to
;; the terminal.
(cl-defstruct (mistty--queue
               (:constructor mistty--make-queue (proc))
               (:conc-name mistty--queue-)
               (:copier nil))
  ;; The process the queue is communicating with.
  proc

  ;; A generator that yields strings to send to the terminal or nil.
  iter

  ;; A list of generator to use after iter
  more-iters

  ;; Timer used by mistty--dequeue-with-timer.
  timer

  ;; Timer called if the process doesn't not answer after a certain
  ;; time.
  timeout

  ;; A function to call to check whether it's time to call the
  ;; generator (if it returns a non-nil value) or whether we should
  ;; keep waiting for output (if it returns nil).
  accept-f)

;; Asynchronous terminal interaction, to add into the queue.
(cl-defstruct (mistty--interact
               (:constructor mistty--make-interact)
               (:conc-name mistty--interact-)
               (:copier nil))
  ;; Callback function that will handle the next call to
  ;; mistty--interact-next. It takes a single argument.
  ;;
  ;; The interaction is finished once the callback returns 'done.
  ;;
  ;; CB initially runs within the buffer that was current when
  ;; `mistty--interact-init' was called. If CB modifies its current
  ;; buffer, it is stored by `mistty--interact-next' and set for the
  ;; next call to CB. The buffer that's current when
  ;; `mistty--interact-next' doesn't matter, though it is guaranteed
  ;; to be restored when it returns.
  ;;
  ;; As such, it is safe to use `set-buffer' within CB, as a buffer
  ;; set that way sticks around between calls to CB and doesn't
  ;; interfere with other pieces of the code.
  cb

  ;; A function that releases any resource held during the
  ;; interaction. It is called once It might be called even if the
  ;; interaction is not ended or never started.
  cleanup

  ;; The buffer that is current for the interaction. It'll be
  ;; set before the next call to CB.
  buf

  ;; The buffer that was current when `mistty--interact-init' was
  ;; called. It is set before calling CLEANUP.
  initial-buf)

(defsubst mistty--interact-init (interact cb &optional cleanup)
  "Convenience function for initializing INTERACT.

This function initializes the fields CB, CLEANUP of INTERACT and
captures the current buffer."
  (setf (mistty--interact-cb interact) cb)
  (let ((buf (current-buffer)))
    (setf (mistty--interact-buf interact) buf)
    (setf (mistty--interact-initial-buf interact) buf))
  (when cleanup
    (setf (mistty--interact-cleanup interact) cleanup)))

(defsubst mistty--interact-return (interact value cb)
  "Convenience function for returning a value from INTERACT.

This function sets CB and returns VALUE."
  (setf (mistty--interact-cb interact) cb)
  value)

(defsubst mistty--queue-empty-p (queue)
  "Return t if QUEUE generator hasn't finished yet."
  (not (mistty--queue-iter queue)))

(defun mistty--send-string (proc str)
  "Send STR to PROC, if it is still live."
  (when (and (mistty--nonempty-str-p str)
             (process-live-p proc))
    (mistty-log "SEND[%s]" str)
    (process-send-string proc str)))

(defun mistty--enqueue-str (queue str &optional fire-and-forget)
  "Enqueue sending STR to the terminal into QUEUE.

Does nothing is STR is nil or empty."
  (when (mistty--nonempty-str-p str)
    (let ((interact (mistty--make-interact)))
      (mistty--interact-init
       interact
       (lambda (&optional _)
         (mistty--interact-return
          interact
          (if fire-and-forget
              `(fire-and-forget ,str)
            str)
          (lambda (&optional_) 'done))))
      (mistty--enqueue
       queue (mistty--interact-adapt interact)))))

(defun mistty--enqueue (queue gen)
  "Add GEN to QUEUE.

The given generator should yield strings to send to the process.
`iter-yield' calls return once some response has been received
from the process or after too long has passed without response.
In the latter case, `iter-yield' returns \\='timeout.

If the queue is empty, this function also kicks things off by
sending the first string generated by GEN to the process.

If the queue is not empty, GEN is appended to the current
generator, to be executed afterwards.

Does nothing if GEN is nil."
  (cl-assert (mistty--queue-p queue))
  (when gen
    (if (mistty--queue-empty-p queue)
        (progn ; This is the first generator; kick things off.
          (setf (mistty--queue-iter queue) gen)
          (mistty--dequeue queue))
      (setf (mistty--queue-more-iters queue)
            (append (mistty--queue-more-iters queue) (list gen))))))

(defun mistty--dequeue (queue &optional value)
  "Send the next string from QUEUE to the terminal.

If VALUE is set, send that value to the first call to `iter-next'."
  (cl-assert (mistty--queue-p queue))
  (mistty--dequeue-1 queue value)
  (unless (mistty--queue-empty-p queue)
    (setf (mistty--queue-timeout queue)
          (run-with-timer
           mistty-timeout-s nil #'mistty--timeout-handler
           (current-buffer) queue))))

(cl-defun mistty--dequeue-1 (queue value)
  "Internal helper for `mistty--dequeue'.

This function does all the work of `mistty-dequeue'. See its
description for the meaning of QUEUE and VALUE."
  (let ((proc (mistty--queue-proc queue)))
    (mistty--cancel-timeout queue)
    (while (mistty--queue-iter queue)
      (condition-case nil
          (progn
            (when-let ((accept-f (mistty--queue-accept-f queue)))
              (condition-case err
                  (unless (funcall accept-f value)
                    (cl-return-from mistty--dequeue-1))
                (error
                 (mistty-log "Accept function failed; giving up: %s" err)))
              (setf (mistty--queue-accept-f queue) nil))
            (while t
              (pcase (iter-next (mistty--queue-iter queue) value)
                ;; Keep waiting
                ('keep-waiting
                 (cl-return-from mistty--dequeue-1))

                ;; Fire-and-forget; no need to wait for a response
                ((and `(fire-and-forget ,str)
                      (guard (mistty--nonempty-str-p str)))
                 (mistty--send-string proc str)
                 (setq value 'fire-and-forget))

                ;; Call iter-next only once accept-f returns non-nil.
                ((and `(until ,str ,accept-f)
                      (guard (mistty--nonempty-str-p str)))
                 (setf (mistty--queue-accept-f queue) accept-f)
                 (mistty--send-string proc str)
                 (cl-return-from mistty--dequeue-1))

                ;; Normal sequences
                ((and (pred mistty--nonempty-str-p) str)
                 (mistty--send-string proc str)
                 (cl-return-from mistty--dequeue-1))

                (invalid (error "Yielded invalid value: '%s'"
                                invalid)))))

        (iter-end-of-sequence
         (setf (mistty--queue-iter queue)
               (pop (mistty--queue-more-iters queue))))))))

(defun mistty--dequeue-with-timer (queue &optional value)
  "Call `mistty--dequeue' on QUEUE with VALUE on a timer.

The idea is to accumulate updates that arrive at the same time
from the process, waiting for it to pause.

This function restarts the timer if a dequeue is already
scheduled."
  (cl-assert (mistty--queue-p queue))
  (mistty--cancel-timeout queue)
  (mistty--cancel-timer queue)
  (unless (mistty--queue-empty-p queue)
    (setf (mistty--queue-timer queue)
          (run-with-timer
           mistty-stable-delay-s nil #'mistty--queue-timer-handler
           (current-buffer) queue value))))

(defun mistty--cancel-queue (queue)
  "Clear QUEUE and cancel all pending actions.

The queue remains usable, but empty."
  (setf (mistty--queue-accept-f queue) nil)
  (when (mistty--queue-iter queue)
    (iter-close (mistty--queue-iter queue))
    (setf (mistty--queue-iter queue) nil))
  (while (mistty--queue-more-iters queue)
    (iter-close (pop (mistty--queue-more-iters queue))))
  (mistty--cancel-timeout queue)
  (mistty--cancel-timer queue))

(defun mistty--cancel-timeout (queue)
  "Cancel the timeout timer in QUEUE."
  (cl-assert (mistty--queue-p queue))
  (when (timerp (mistty--queue-timeout queue))
    (cancel-timer (mistty--queue-timeout queue))
    (setf (mistty--queue-timeout queue) nil)))

(defun mistty--cancel-timer (queue)
  "Cancel the timer in QUEUE."
  (cl-assert (mistty--queue-p queue))
  (when (timerp (mistty--queue-timer queue))
    (cancel-timer (mistty--queue-timer queue))
    (setf (mistty--queue-timer queue) nil)))

(defun mistty--timeout-handler (buf queue)
  "Handle timeout in QUEUE.

The code is executed inside BUF.

This function is meant to be use as timer handler."
  (cl-assert (mistty--queue-p queue))
  (mistty--with-live-buffer buf
    (let ((proc (mistty--queue-proc queue)))
      (when (and (mistty--queue-timeout queue)
                 ;; last chance, in case some scheduling kerfuffle meant
                 ;; process output ended up buffered.
                 (not (and (process-live-p proc)
                           (accept-process-output proc 0 nil t))))
        (setf (mistty--queue-timeout queue) nil)
        (mistty-log "TIMEOUT")
        (mistty--dequeue queue 'timeout)))))

(defun mistty--queue-timer-handler (buf queue value)
  "Call `mistty--dequeue' on QUEUE in an idle timer.

VALUE is passed to `mistty--dequeue'.

The code is executed inside BUF.

This function is meant to be use as timer handler."
  (cl-assert (mistty--queue-p queue))
  (mistty--with-live-buffer buf
    (setf (mistty--queue-timer queue) nil)
    (mistty--dequeue queue value)))

(defun mistty--interact-next (interact &optional val)
  "Return the next value from INTERACT."
  (with-current-buffer (mistty--interact-buf interact)
    (prog1 (funcall (mistty--interact-cb interact) val)
      (setf (mistty--interact-buf interact) (current-buffer)))))

(defun mistty--interact-close (interact)
  "Close INTERACT, releasing any resource it helds.

After this call, `mistty--interact-next' fails and
`mistty--interact-close' is a no-op."
  (setf (mistty--interact-cb interact)
        (lambda (&optional _)
          (error "Interaction was closed")))
  (when-let ((func (mistty--interact-cleanup interact)))
    (setf (mistty--interact-cleanup interact) nil)
    (with-current-buffer (mistty--interact-initial-buf interact)
      (funcall func))))

(defun mistty--interact-adapt (interact)
  "Transform INTERACT into a generator."
  (lambda (cmd val)
    (cond
     ((eq cmd :next)
      (let ((ret (mistty--interact-next interact val)))
        (when (eq 'done ret)
          (mistty--interact-close interact)
          (signal 'iter-end-of-sequence nil))
        ret))
     ((eq cmd :close)
      (mistty--interact-close interact))
     (t (error "Unknown command %s" cmd)))))
  
(provide 'mistty-queue)

;;; mistty-queue.el ends here
