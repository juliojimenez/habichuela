(in-package #:habichuela)

;;; Ultralisp membership. Ultralisp (https://ultralisp.org) is a Quicklisp-compatible
;;; distribution that builds projects straight from their repositories. Its release index
;;; lists every project with a release in the current dist version, one per line, and
;;; names projects after the repository with the slash turned into a hyphen:
;;; hu-dwim/hu.dwim.zlib is hu-dwim-hu.dwim.zlib. A repository is "in Ultralisp" when
;;; that name has a release. The index is fetched at most once per run.

(defparameter *ultralisp-distinfo-url* "https://dist.ultralisp.org/ultralisp.txt"
  "The dist info file: 'key: value' lines, one of them release-index-url.")

(defvar *ultralisp-index* :unloaded
  "Lowercased dist project name -> name as written, for the current Ultralisp dist.
NIL when the index could not be fetched this run.")

(defun lines (text)
  (mapcar (lambda (line) (string-trim '(#\Space #\Return) line))
          (uiop:split-string text :separator (string #\Newline))))

(defun distinfo-value (text key)
  "The value of KEY in a Quicklisp distinfo TEXT, or NIL."
  (loop for line in (lines text)
        for colon = (position #\: line)
        when (and colon (string= (subseq line 0 colon) key))
          return (string-trim " " (subseq line (1+ colon)))))

(defun parse-release-index (text)
  "Lowercased project name -> project name for every release line of a releases.txt."
  (let ((names (make-hash-table :test 'equal)))
    (dolist (line (lines text) names)
      (unless (or (zerop (length line)) (char= (char line 0) #\#))
        (let ((name (subseq line 0 (position #\Space line))))
          (setf (gethash (lc name) names) name))))))

(defun fetch-ultralisp-index ()
  (let* ((distinfo (fetch-text *ultralisp-distinfo-url*))
         (url (and distinfo (distinfo-value distinfo "release-index-url"))))
    (unless url
      (error "No release-index-url in ~a" *ultralisp-distinfo-url*))
    (let ((index (parse-release-index (or (fetch-text url) ""))))
      (log-line "Ultralisp: ~d projects in dist ~a" (hash-table-count index)
                (or (distinfo-value distinfo "version") "?"))
      index)))

(defun ultralisp-index ()
  "The project name table, fetched on first use. NIL when Ultralisp was unreachable."
  (when (eq *ultralisp-index* :unloaded)
    (setf *ultralisp-index*
          (handler-case (fetch-ultralisp-index)
            (error (e)
              (log-line "Ultralisp index unavailable (~a); membership left as it was" e)
              nil))))
  *ultralisp-index*)

(defun ultralisp-dist-name (ref)
  "The name Ultralisp gives REF's repository: owner and name joined with a hyphen."
  (substitute #\- #\/ (repo-ref-name ref)))

(defun ultralisp-project (ref &optional previous)
  "REF's project name in the current Ultralisp dist, NIL when it has no release there.
PREVIOUS, the value already on record, is returned when the index could not be fetched."
  (let ((index (ultralisp-index)))
    (if index
        (values (gethash (lc (ultralisp-dist-name ref)) index))
        previous)))
