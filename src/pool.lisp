(in-package #:habichuela)

;;; The curated pool is every Quicklisp project hosted on a forge we can read,
;;; taken from a shallow clone of github.com/quicklisp/quicklisp-projects (see
;;; `make pool`). Each project directory has a source.txt whose lines point at
;;; the upstream repository.

(defun pool-projects ()
  "List of (project-name . repo-ref), one entry per distinct repository."
  (let ((dir (pool-dir)))
    (unless (probe-file dir)
      (error "Quicklisp projects list not found at ~a. Run: make pool" dir))
    (let ((seen (make-hash-table :test 'equal))
          (result '()))
      (dolist (sub (uiop:subdirectories dir))
        (let ((source (merge-pathnames "source.txt" sub)))
          (when (probe-file source)
            (dolist (line (uiop:read-file-lines source))
              (let ((ref (parse-repo-url line)))
                (when (and ref (not (gethash (ref-key ref) seen)))
                  (setf (gethash (ref-key ref) seen) t)
                  (push (cons (car (last (pathname-directory sub))) ref) result)))))))
      (nreverse result))))

(defun pool-summary (projects)
  "Count of pool projects per forge, as an alist."
  (let ((counts '()))
    (dolist (p projects counts)
      (let ((forge (repo-ref-forge (cdr p))))
        (if (assoc forge counts)
            (incf (cdr (assoc forge counts)))
            (push (cons forge 1) counts))))))
