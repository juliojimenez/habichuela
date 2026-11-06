(in-package #:habichuela)

;;; HTTP for the forge APIs: dexador over pure-tls. TLS is pure Lisp, so no
;;; OpenSSL version can break it; see habichuela.asd for how cl+ssl is kept out.

(define-condition api-error (error)
  ((status :initarg :status :reader api-status :initform nil)
   (url :initarg :url :reader api-url)
   (body :initarg :body :reader api-body :initform nil))
  (:report (lambda (c s)
             (format s "~@[HTTP ~a ~]for ~a~@[: ~a~]" (api-status c) (api-url c) (api-body c)))))

(define-condition api-not-found (api-error) ())

(defun url-encode (string)
  "Percent-encode STRING for use as a path segment or query-string value."
  (with-output-to-string (out)
    (loop for octet across #+sbcl (sb-ext:string-to-octets string :external-format :utf-8)
                           #-sbcl (map 'vector #'char-code string)
          for char = (code-char octet)
          do (if (and (< octet 128) (or (alphanumericp char) (find char "-._~")))
                 (write-char char out)
                 (format out "%~2,'0X" octet)))))

(defun body-text (body)
  (cond ((null body) "")
        ((stringp body) body)
        (t (babel:octets-to-string body :encoding :utf-8 :errorp nil))))

(defun check-complete (url body response-headers)
  "Signal API-ERROR when a Content-Length header promises more bytes than BODY holds.
A connection cut mid-response otherwise looks like a short, unparseable body."
  (let* ((declared (ignore-errors (parse-integer (gethash "content-length" response-headers ""))))
         (encoding (gethash "content-encoding" response-headers)))
    (when (and declared (null encoding))
      (let ((received (if (stringp body)
                          (length (babel:string-to-octets body :encoding :utf-8))
                          (length body))))
        (unless (= declared received)
          (error 'api-error :url url
                            :body (format nil "truncated response: ~d of ~d bytes" received declared)))))))

(defun http-get (url headers)
  "GET URL. Returns (values body-string http-status) for any HTTP answer, including
4xx and 5xx. Transport, TLS and truncation failures signal API-ERROR."
  (handler-case
      (multiple-value-bind (body status response-headers)
          (dex:get url :headers headers :connect-timeout 20 :read-timeout 60)
        (check-complete url body response-headers)
        (values (body-text body) status))
    (dex:http-request-failed (e)
      (values (body-text (dex:response-body e)) (dex:response-status e)))
    (error (e)
      (error 'api-error :url url :body (format nil "~a" e)))))

(defun scrub-control-characters (string)
  "Drop raw control characters other than tab, newline and return. GitLab has been seen
emitting a literal NUL inside a JSON string, which is invalid JSON and must not abort a run."
  (if (find-if (lambda (c) (and (< (char-code c) 32) (not (member c '(#\Tab #\Newline #\Return))))) string)
      (remove-if (lambda (c) (and (< (char-code c) 32) (not (member c '(#\Tab #\Newline #\Return))))) string)
      string))

(defun parse-json (body url)
  "Parse BODY as JSON; any parse failure becomes an API-ERROR for URL."
  (handler-case (jzon:parse (scrub-control-characters body))
    (error (e)
      (error 'api-error :url url :body (format nil "unparseable JSON: ~a" (body-snippet (princ-to-string e)))))))

(defun body-snippet (body)
  (when (and (stringp body) (plusp (length body)))
    (string-trim '(#\Space #\Newline #\Return) (subseq body 0 (min 300 (length body))))))

(defun api-get (url &key headers (retries 2))
  "GET a JSON API URL and return the parsed value. 404, 410 and 451 signal API-NOT-FOUND,
other failures API-ERROR. Transport and server errors are retried RETRIES times."
  (loop with attempts = (1+ retries)
        for attempt from 1 to attempts
        do (multiple-value-bind (body status)
               (handler-case (http-get url headers)
                 (api-error (e)
                   (if (< attempt attempts)
                       (progn (log-line "~a, retrying" e) (sleep (* 3 attempt)) (values nil nil))
                       (error e))))
             (cond ((null status))
                   ((<= 200 status 299) (return (parse-json body url)))
                   ((member status '(404 410 451))
                    (error 'api-not-found :status status :url url))
                   ((and (>= status 500) (< attempt attempts))
                    (log-line "HTTP ~a for ~a, retrying" status url)
                    (sleep (* 3 attempt)))
                   (t (error 'api-error :status status :url url :body (body-snippet body)))))))

(defun fetch-text (url &key (headers '(("User-Agent" . "habichuela"))))
  "Body of URL for a 2xx response, NIL when it does not exist. Other failures signal API-ERROR."
  (multiple-value-bind (body status) (http-get url headers)
    (cond ((and status (<= 200 status 299)) body)
          ((member status '(404 410 451)) nil)
          (t (error 'api-error :status status :url url :body (body-snippet body))))))
