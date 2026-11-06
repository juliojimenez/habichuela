(in-package #:habichuela)

;;; pure-tls 1.15.2 returns short reads from STREAM-READ-SEQUENCE: once the first
;;; buffer fill has succeeded, it gives up as soon as the socket has no bytes ready,
;;; to avoid deadlocking with a peer that waits for a reply. READ-SEQUENCE callers
;;; expect a full read or end of file, and dexador reads a Content-Length body with a
;;; single call, so any server that delivers slower than we read yields a body whose
;;; tail is NUL bytes. That is what broke the 2026-11-06 run. This method restores the
;;; blocking contract for our image only. Delete it once pure-tls fixes it upstream.

(defmethod trivial-gray-streams:stream-read-sequence ((stream pure-tls::tls-stream) sequence start end &key)
  (when (pure-tls::tls-stream-record-layer stream)
    (pure-tls::check-tls-context))
  (if (pure-tls::tls-stream-closed-p stream)
      start
      (let ((pos start))
        (loop while (< pos end)
              do (when (zerop (pure-tls::tls-stream-buffer-remaining stream))
                   (handler-case (pure-tls::tls-stream-fill-buffer stream)
                     (pure-tls::tls-connection-closed () (return pos))))
                 (let ((to-copy (min (pure-tls::tls-stream-buffer-remaining stream) (- end pos))))
                   (when (zerop to-copy)
                     (return pos))
                   (replace sequence (pure-tls::tls-stream-input-buffer stream)
                            :start1 pos :end1 (+ pos to-copy)
                            :start2 (pure-tls::tls-stream-input-position stream))
                   (incf pos to-copy)
                   (incf (pure-tls::tls-stream-input-position stream) to-copy))
              finally (return pos)))))
