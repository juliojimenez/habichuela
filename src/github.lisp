(in-package #:habichuela)

;;; GitHub REST client. HTTP goes through curl rather than a Lisp TLS stack:
;;; cl+ssl (which every Lisp HTTP client uses) does not work with OpenSSL 4 yet,
;;; and curl is present on every machine this runs on. The token is passed to
;;; curl through a config on stdin, so it never appears in the process list.

(defparameter *api-base* "https://api.github.com")

(define-condition gh-error (error)
  ((status :initarg :status :reader gh-status :initform nil)
   (url :initarg :url :reader gh-url)
   (body :initarg :body :reader gh-body :initform nil))
  (:report (lambda (c s)
             (format s "GitHub API ~@[HTTP ~a ~]for ~a~@[: ~a~]"
                     (gh-status c) (gh-url c) (gh-body c)))))

(define-condition gh-not-found (gh-error) ())

(defun gh-token () (env "GITHUB_TOKEN" (env "GH_TOKEN")))

(defun gh-headers ()
  (append '(("Accept" . "application/vnd.github+json")
            ("X-GitHub-Api-Version" . "2022-11-28")
            ("User-Agent" . "habichuela"))
          (let ((token (gh-token)))
            (when token (list (cons "Authorization" (format nil "Bearer ~a" token)))))))

(defun curl-config (url headers output-path)
  "A curl config file. ~s quoting matches curl's double-quoted syntax."
  (with-output-to-string (s)
    (format s "url = ~s~%" url)
    (format s "silent~%show-error~%location~%connect-timeout = 20~%max-time = 60~%")
    (format s "output = ~s~%" (uiop:native-namestring output-path))
    (format s "write-out = \"%{http_code}\"~%")
    (dolist (h headers)
      (format s "header = ~s~%" (format nil "~a: ~a" (car h) (cdr h))))))

(defun http-get (url headers)
  "GET URL. Returns (values body-string http-status). Signals GH-ERROR when curl itself fails."
  (uiop:with-temporary-file (:pathname body-path :prefix "habichuela-" :type "json")
    (multiple-value-bind (out err code)
        (uiop:run-program (list "curl" "--config" "-")
                          :input (make-string-input-stream (curl-config url headers body-path))
                          :output :string :error-output :string :ignore-error-status t)
      (unless (zerop code)
        (error 'gh-error :url url
                         :body (format nil "curl exit ~d: ~a" code
                                       (string-trim '(#\Space #\Newline) err))))
      (values (if (probe-file body-path)
                  (uiop:read-file-string body-path :external-format :utf-8)
                  "")
              (parse-integer (string-trim '(#\Space #\Newline) out) :junk-allowed t)))))

(defun body-snippet (body)
  (when (and (stringp body) (plusp (length body)))
    (subseq body 0 (min 300 (length body)))))

(defun gh-get (path)
  "GET an API path and return the parsed JSON. 404, 410 and 451 signal GH-NOT-FOUND,
other failures GH-ERROR. Transport and server errors are retried twice."
  (let ((url (if (starts-with "http" path) path (concatenate 'string *api-base* path))))
    (loop for attempt from 1 to 3
          do (multiple-value-bind (body status)
                 (handler-case (http-get url (gh-headers))
                   (gh-error (e)
                     (if (< attempt 3)
                         (progn (log-line "~a, retrying" e) (sleep (* 3 attempt)) (values nil nil))
                         (error e))))
               (cond ((null status))
                     ((<= 200 status 299) (return (jzon:parse body)))
                     ((member status '(404 410 451))
                      (error 'gh-not-found :status status :url url))
                     ((and (>= status 500) (< attempt 3))
                      (log-line "GitHub returned ~a for ~a, retrying" status url)
                      (sleep (* 3 attempt)))
                     (t (error 'gh-error :status status :url url :body (body-snippet body))))))))

(defun gh-repo (full-name)
  (gh-get (format nil "/repos/~a" full-name)))

(defun gh-tree (full-name branch)
  "Paths of every blob and tree in BRANCH, and whether GitHub truncated the listing."
  (let ((json (gh-get (format nil "/repos/~a/git/trees/~a?recursive=1" full-name branch))))
    (values (mapcar (lambda (e) (jget e "path" "")) (to-list (jget json "tree")))
            (truthy (jget json "truncated")))))

(defun url-encode (string)
  "Percent-encode STRING for use as a query-string value."
  (with-output-to-string (out)
    (loop for octet across #+sbcl (sb-ext:string-to-octets string :external-format :utf-8)
                           #-sbcl (map 'vector #'char-code string)
          for char = (code-char octet)
          do (if (and (< octet 128) (or (alphanumericp char) (find char "-._~")))
                 (write-char char out)
                 (format out "%~2,'0X" octet)))))

(defun gh-search-repos (query &key (sort "updated") (order "desc") (per-page 100) (page 1))
  "Repository search. Returns (values items total-count incomplete-p)."
  (let ((json (gh-get (format nil "/search/repositories?q=~a&sort=~a&order=~a&per_page=~d&page=~d"
                              (url-encode query) sort order per-page page))))
    (values (to-list (jget json "items"))
            (jget json "total_count" 0)
            (truthy (jget json "incomplete_results")))))
