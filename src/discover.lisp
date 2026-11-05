(in-package #:habichuela)

;;; Discovery outside Quicklisp: GitHub repository search for Common Lisp
;;; repositories, one month of creation dates at a time. Every month since
;;; GitHub launched gets the same odds, so quiet years surface as often as
;;; busy ones. Search returns at most 1000 results per query, which is why
;;; the pool is sliced by month instead of fetched whole.

(defparameter *discovery-min-stars* 3
  "Minimum stars for repositories found through search. GitHub has no curation,
so the bar is a little higher than for Quicklisp projects.")
(defparameter *discovery-max-windows* 8
  "Months to search before falling back to the Quicklisp list for the day.")

(defun days-in-month (year month)
  (if (= month 12)
      31
      (floor (- (encode-universal-time 0 0 0 1 (1+ month) year 0)
                (encode-universal-time 0 0 0 1 month year 0))
             86400)))

(defun month-windows (date)
  "created: ranges for every month from 2008-01 up to the month of DATE, oldest first."
  (let ((end-year (parse-integer date :start 0 :end 4))
        (end-month (parse-integer date :start 5 :end 7)))
    (loop for year from 2008 to end-year
          append (loop for month from 1 to (if (= year end-year) end-month 12)
                       collect (format nil "~4,'0d-~2,'0d-01..~4,'0d-~2,'0d-~2,'0d"
                                       year month year month (days-in-month year month))))))

(defun discovery-query (window)
  (format nil "language:\"Common Lisp\" stars:>=~d fork:false archived:false created:~a"
          *discovery-min-stars* window))

(defun search-window (window)
  "owner/name of the repositories created in WINDOW, most recently updated first."
  (multiple-value-bind (items total incomplete) (gh-search-repos (discovery-query window))
    (log-line "  created ~a: ~d repositor~:@p~:[~; (incomplete results)~]" window total total incomplete)
    (mapcar (lambda (item) (jget item "full_name")) items)))
