;;; -*- Mode: Lisp; Package: CLIM-INTERNALS -*-

;;;  (c) copyright 2001 by 
;;;           Tim Moore (moore@bricoworks.com)
;;;  (c) copyright 2006 by
;;           Troels Henriksen (athas@sigkill.dk)

;;; This library is free software; you can redistribute it and/or
;;; modify it under the terms of the GNU Library General Public
;;; License as published by the Free Software Foundation; either
;;; version 2 of the License, or (at your option) any later version.
;;;
;;; This library is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;; Library General Public License for more details.
;;;
;;; You should have received a copy of the GNU Library General Public
;;; License along with this library; if not, write to the 
;;; Free Software Foundation, Inc., 59 Temple Place - Suite 330, 
;;; Boston, MA  02111-1307  USA.

;;; Finalize input editing code by defining the stuff that actually
;;; needs a working Drei loaded.

(in-package :clim-internals)

(defclass empty-input-mixin ()
  ()
  (:documentation "A mixin class used for detecting empty input"))

(defclass standard-input-editing-stream (drei:drei-input-editing-mixin
					 empty-input-mixin
                                         standard-input-editing-mixin
					 input-editing-stream
					 standard-encapsulating-stream)
  ((scan-pointer :accessor stream-scan-pointer :initform 0)
   (rescan-queued :accessor rescan-queued :initform nil))
  (:documentation "The instantiable class that implements CLIM's
standard input editor. This is the class of stream created by
calling `with-input-editing'.

Members of this class are mutable."))

(defmethod interactive-stream-p ((stream standard-input-editing-stream))
  t)

(defmethod stream-accept ((stream standard-input-editing-stream) type
			  &rest args
			  &key (view (stream-default-view stream))
			  &allow-other-keys)
  (apply #'prompt-for-accept stream type view args)
  (apply #'accept-1 stream type args))

;;; Markers for noise strings in the input buffer.

(defclass noise-string-property ()
  ())

(defclass noise-string-start-property (noise-string-property)
  ())

(defparameter *noise-string* (make-instance 'noise-string-property))

(defparameter *noise-string-start*
  (make-instance 'noise-string-start-property))

(defgeneric activate-stream (stream gesture)
  (:documentation "Cause the input editing stream STREAM to be
activated with GESTURE"))

(defmethod activate-stream ((stream standard-input-editing-stream) gesture)
  (setf (drei::activation-gesture stream) gesture))

;;; These helper functions take the arguments of ACCEPT so that they
;;; can be used directly by ACCEPT.

(defun make-activation-gestures
    (&key (activation-gestures nil activation-gestures-p)
     (additional-activation-gestures nil additional-activations-p)
     (existing-activation-gestures *activation-gestures*)
     &allow-other-keys)
  (cond (additional-activations-p
	 (append additional-activation-gestures existing-activation-gestures))
	(activation-gestures-p
	 activation-gestures)
	(t (or existing-activation-gestures
	       *standard-activation-gestures*))))

(defun make-delimiter-gestures
    (&key (delimiter-gestures nil delimiter-gestures-p)
     (additional-delimiter-gestures nil additional-delimiters-p)
     (existing-delimiter-gestures *delimiter-gestures*)
     &allow-other-keys)
  (cond (additional-delimiters-p
	 (append additional-delimiter-gestures existing-delimiter-gestures))
	(delimiter-gestures-p
	 delimiter-gestures)
	(t existing-delimiter-gestures)))

(define-condition rescan-condition (condition)
  ())

(defmethod finalize ((stream drei:drei-input-editing-mixin)
                     input-sensitizer)
  (call-next-method)
  (setf (cursor-visibility stream) nil)
  (let ((real-stream (encapsulating-stream-stream stream))
	(record (drei:drei-instance stream)))
    (cond (input-sensitizer
           (erase-output-record record real-stream)
           (funcall input-sensitizer
                    real-stream
                    #'(lambda ()
                        (stream-add-output-record real-stream record)
                        (when (stream-drawing-p real-stream)
                          (replay record real-stream)))))
          ;; We still want to replay it for the cursor visibility
          ;; change...
          ((stream-drawing-p real-stream)
           (replay record real-stream) ))
    (setf (stream-cursor-position real-stream)
          (values 0 (bounding-rectangle-max-y (input-editing-stream-output-record stream))))))

;; XXX: We are supposed to implement input editing for all
;; "interactive streams", but that's not really reasonable. We only
;; care about `clim-stream-pane's, at least for Drei, currently.
(defmethod invoke-with-input-editing ((stream clim-stream-pane)
				      continuation
				      input-sensitizer
				      initial-contents
				      class)
  (let ((editing-stream (make-instance class :stream stream)))
    (unwind-protect (with-input-editing (editing-stream
                                         :input-sensitizer input-sensitizer
                                         :initial-contents initial-contents
                                         :class class)
                      (input-editing-rescan-loop editing-stream continuation))
      (finalize editing-stream input-sensitizer))))

(defmethod immediate-rescan ((stream standard-input-editing-stream))
  (unless (stream-rescanning-p stream)
    (signal 'rescan-condition)))

(defmethod queue-rescan ((stream standard-input-editing-stream))
  (setf (rescan-queued stream) t))

(defmethod rescan-if-necessary ((stream standard-input-editing-stream)
				&optional inhibit-activation)
  ;; FIXME:
  (declare (ignore inhibit-activation))
  (when (rescan-queued stream)
    (setf (rescan-queued stream) nil)
    (immediate-rescan stream)))

(defmethod input-editing-stream-output-record ((stream standard-input-editing-stream))
  (drei:drei-instance stream))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; 
;;; Presentation type history support
;;;
;;; Presentation histories are pretty underspecified, so we have to
;;; rely on internal features and implement input-editor support in
;;; CLIM-INTERNALS (Goatee does the same trick).

(defun history-yank-next (stream input-buffer gesture numeric-argument)
  (declare (ignore input-buffer gesture numeric-argument))
  (let* ((accepting-type *active-history-type*)
         (history (and accepting-type
                       (presentation-type-history accepting-type))))
    (when history
      (multiple-value-bind (object type)
          (presentation-history-next history accepting-type)
        (when type
          (presentation-replace-input stream object type (stream-default-view stream)
                                      :allow-other-keys t
                                      :accept-result nil))))))

(defun history-yank-previous (stream input-buffer gesture numeric-argument)
  (declare (ignore input-buffer gesture numeric-argument))
  (let* ((accepting-type *active-history-type*)
         (history (and accepting-type
                       (presentation-type-history accepting-type))))
    (when history
      (multiple-value-bind (object type)
          (presentation-history-previous history accepting-type)
        (when type
          (presentation-replace-input stream object type (stream-default-view stream)
                                      :allow-other-keys t
                                      :accept-result nil))))))

(add-input-editor-command '((#\n :meta)) 'history-yank-next)

(add-input-editor-command '((#\p :meta)) 'history-yank-previous)
