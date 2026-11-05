(in-package #:habichuela)

;;; Environment and paths

(defun env (name &optional default)
  "Value of environment variable NAME, or DEFAULT when unset or empty."
  (let ((v (uiop:getenv name)))
    (if (and v (plusp (length v))) v default)))

(defun root ()
  "Project root: HABICHUELA_ROOT or the current directory."
  (uiop:ensure-directory-pathname (env "HABICHUELA_ROOT" (uiop:getcwd))))

(defun data-dir () (merge-pathnames "data/" (root)))
(defun site-dir () (merge-pathnames "site/" (root)))
(defun pool-dir () (merge-pathnames "build/quicklisp-projects/projects/" (root)))

(defun log-line (control &rest args)
  (format *error-output* "~&~?~%" control args)
  (finish-output *error-output*))

;;; Strings

(defun lc (s) (string-downcase s))
(defun starts-with (prefix s) (alex:starts-with-subseq prefix s))
(defun ends-with (suffix s) (alex:ends-with-subseq suffix s))

(defun blank-p (s)
  (or (null s) (not (stringp s)) (zerop (length (string-trim '(#\Space #\Tab #\Newline) s)))))

;;; Dates. Everything is UTC.

(defparameter +iso-format+
  '(:year "-" (:month 2) "-" (:day 2) "T" (:hour 2) ":" (:min 2) ":" (:sec 2) "Z"))
(defparameter +date-format+ '(:year "-" (:month 2) "-" (:day 2)))

(defun now-iso ()
  (local-time:format-timestring nil (local-time:now)
                                :format +iso-format+ :timezone local-time:+utc-zone+))

(defun today ()
  "Today's date as YYYY-MM-DD, or HABICHUELA_DATE when set."
  (or (env "HABICHUELA_DATE")
      (local-time:format-timestring nil (local-time:now)
                                    :format +date-format+ :timezone local-time:+utc-zone+)))

(defun valid-date-p (s)
  (and (stringp s) (= (length s) 10)
       (char= (char s 4) #\-) (char= (char s 7) #\-)
       (every (lambda (i) (digit-char-p (char s i))) '(0 1 2 3 5 6 8 9))))

(defun date-seed (date)
  "Deterministic integer seed for a YYYY-MM-DD date."
  (parse-integer (remove #\- date)))

(defun date-universal (date)
  "Universal time at UTC midnight of a YYYY-MM-DD date."
  (encode-universal-time 0 0 0
                         (parse-integer date :start 8 :end 10)
                         (parse-integer date :start 5 :end 7)
                         (parse-integer date :start 0 :end 4)
                         0))

(defun days-between (earlier later)
  "Whole days from EARLIER to LATER, both YYYY-MM-DD."
  (floor (- (date-universal later) (date-universal earlier)) 86400))

(defun days-since (iso)
  "Whole days from an ISO 8601 timestamp string until now, or NIL if unparsable."
  (let ((ts (and (stringp iso) (ignore-errors (local-time:parse-timestring iso)))))
    (when ts
      (floor (- (get-universal-time) (local-time:timestamp-to-universal ts)) 86400))))

(defun humanize-days (d)
  (cond ((< d 1) "today")
        ((< d 2) "yesterday")
        ((< d 30) (format nil "~d days ago" d))
        ((< d 365) (format nil "~d month~:p ago" (max 1 (round d 30))))
        (t (format nil "~,1f years ago" (/ d 365.25)))))

(defun date-part (iso)
  (if (and (stringp iso) (>= (length iso) 10)) (subseq iso 0 10) ""))

;;; JSON. Records are string-keyed EQUAL hash tables, as jzon parses them.
;;; jzon's spelling of true/false/null is probed at load time so the code
;;; does not depend on its symbol conventions.

(defparameter *json-false*
  (loop for c in (list nil :false 'false) when (string= (jzon:stringify c) "false") return c))
(defparameter *json-null*
  (loop for c in (list 'null :null nil) when (string= (jzon:stringify c) "null") return c))

(defun json-bool (x) (if x t *json-false*))
(defun json-or-null (x) (if (null x) *json-null* x))

(defun truthy (v)
  "Generalized JSON truth: false, null and empty strings are false."
  (not (or (null v) (eq v 'null) (eq v :null) (eq v :false)
           (and (stringp v) (zerop (length v))))))

(defun jget (obj key &optional default)
  "Value of KEY in a parsed JSON object, DEFAULT when missing or null."
  (if (hash-table-p obj)
      (multiple-value-bind (v found) (gethash key obj)
        (if (and found (not (eq v 'null)) (not (eq v :null))) v default))
      default))

(defun record (&rest kvs)
  "Build a string-keyed hash table, keeping the key order given."
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr do (setf (gethash k h) v))
    h))

(defun to-list (v)
  (cond ((null v) nil)
        ((stringp v) (list v))
        ((listp v) v)
        ((vectorp v) (coerce v 'list))
        (t (list v))))

(defun read-json-file (path) (jzon:parse path))

(defun write-json-file (path obj)
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :if-exists :supersede :external-format :utf-8)
    (jzon:stringify obj :stream out :pretty t)
    (terpri out)))

(defun write-text-file (path text)
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :if-exists :supersede :external-format :utf-8)
    (write-string text out)))

;;; Seeded randomness, so a rerun on the same day makes the same choices.

(defun seeded-random-state (seed)
  #+sbcl (sb-ext:seed-random-state seed)
  #-sbcl (make-random-state t))

(defun seeded-shuffle (list seed)
  (let ((*random-state* (seeded-random-state seed)))
    (alex:shuffle (copy-list list))))
