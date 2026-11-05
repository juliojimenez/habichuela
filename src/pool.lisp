(in-package #:habichuela)

;;; The candidate pool is every Quicklisp project hosted on GitHub, read from a
;;; shallow clone of github.com/quicklisp/quicklisp-projects (see `make pool`).
;;; Each project directory has a source.txt whose lines point at the upstream.

(defun github-repo-in-line (line)
  "owner/name when LINE contains a github.com URL, else NIL."
  (let ((pos (search "github.com/" line)))
    (when pos
      (let* ((rest (subseq line (+ pos (length "github.com/"))))
             (parts (uiop:split-string rest :separator '(#\/ #\Space #\Tab #\Return)))
             (owner (first parts))
             (name (second parts)))
        (when (and owner name (plusp (length owner)) (plusp (length name)))
          (when (ends-with ".git" name)
            (setf name (subseq name 0 (- (length name) 4))))
          (when (plusp (length name))
            (format nil "~a/~a" owner name)))))))

(defun pool-projects ()
  "List of (project-name . owner/name), one entry per distinct GitHub repository."
  (let ((dir (pool-dir)))
    (unless (probe-file dir)
      (error "Quicklisp projects list not found at ~a. Run: make pool" dir))
    (let ((seen (make-hash-table :test 'equal))
          (result '()))
      (dolist (sub (uiop:subdirectories dir))
        (let ((source (merge-pathnames "source.txt" sub)))
          (when (probe-file source)
            (dolist (line (uiop:read-file-lines source))
              (let ((repo (github-repo-in-line line)))
                (when (and repo (not (gethash (lc repo) seen)))
                  (setf (gethash (lc repo) seen) t)
                  (push (cons (car (last (pathname-directory sub))) repo) result)))))))
      (nreverse result))))
