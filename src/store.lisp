(in-package #:habichuela)

;;; One JSON file per day under data/: data/YYYY-MM-DD.json.
;;; The file holds the pick (date, repo) and the latest stats snapshot.

(defun record-path (date)
  (merge-pathnames (format nil "~a.json" date) (data-dir)))

(defun record-files ()
  "Record files, newest date first."
  (sort (remove-if-not (lambda (p) (valid-date-p (pathname-name p)))
                       (uiop:directory-files (data-dir) "*.json"))
        #'string> :key #'pathname-name))

(defun list-records ()
  "All records, newest first."
  (mapcar #'read-json-file (record-files)))

(defun save-record (rec)
  (write-json-file (record-path (jget rec "date")) rec))

(defun record-repo (rec) (jget rec "repo" ""))

(defun record-owner (rec)
  (let ((repo (record-repo rec)))
    (subseq repo 0 (position #\/ repo))))

(defun picked-repos (records)
  (mapcar (lambda (r) (lc (record-repo r))) records))

(defun excluded-repos ()
  "owner/name entries from data/exclude.txt, lowercased."
  (let ((path (merge-pathnames "exclude.txt" (data-dir))))
    (when (probe-file path)
      (loop for line in (uiop:read-file-lines path)
            for s = (string-trim '(#\Space #\Tab #\Return) line)
            unless (or (zerop (length s)) (char= (char s 0) #\#))
              collect (lc s)))))

(defun recent-owners (records date days)
  "Owners featured within DAYS before DATE, lowercased."
  (loop for r in records
        for d = (jget r "date")
        when (and (valid-date-p d) (<= 0 (days-between d date) days))
          collect (lc (record-owner r))))

(defun record-ref (rec)
  "The REPO-REF a record points at. Records written before forges were tracked are GitHub."
  (let ((host (jget rec "host" "github.com")))
    (make-repo-ref (or (forge-for-host host) :github) host (record-repo rec))))
