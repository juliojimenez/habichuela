(in-package #:habichuela)

;;; HTTP for the forge APIs. Requests go through curl rather than a Lisp TLS
;;; stack: cl+ssl, which every Lisp HTTP client uses, does not work with
;;; OpenSSL 4 yet, and curl is present on every machine this runs on. Tokens
;;; travel to curl in a config on stdin, so they never show in the process list.

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
  "GET URL. Returns (values body-string http-status). Signals API-ERROR when curl itself fails."
  (uiop:with-temporary-file (:pathname body-path :prefix "habichuela-" :type "json")
    (multiple-value-bind (out err code)
        (uiop:run-program (list "curl" "--config" "-")
                          :input (make-string-input-stream (curl-config url headers body-path))
                          :output :string :error-output :string :ignore-error-status t)
      (unless (zerop code)
        (error 'api-error :url url
                          :body (format nil "curl exit ~d: ~a" code
                                        (string-trim '(#\Space #\Newline) err))))
      (values (if (probe-file body-path)
                  (uiop:read-file-string body-path :external-format :utf-8)
                  "")
              (parse-integer (string-trim '(#\Space #\Newline) out) :junk-allowed t)))))

(defun body-snippet (body)
  (when (and (stringp body) (plusp (length body)))
    (subseq body 0 (min 300 (length body)))))

(defun api-get (url &key headers)
  "GET a JSON API URL and return the parsed value. 404, 410 and 451 signal API-NOT-FOUND,
other failures API-ERROR. Transport and server errors are retried twice."
  (loop for attempt from 1 to 3
        do (multiple-value-bind (body status)
               (handler-case (http-get url headers)
                 (api-error (e)
                   (if (< attempt 3)
                       (progn (log-line "~a, retrying" e) (sleep (* 3 attempt)) (values nil nil))
                       (error e))))
             (cond ((null status))
                   ((<= 200 status 299) (return (jzon:parse body)))
                   ((member status '(404 410 451))
                    (error 'api-not-found :status status :url url))
                   ((and (>= status 500) (< attempt 3))
                    (log-line "HTTP ~a for ~a, retrying" status url)
                    (sleep (* 3 attempt)))
                   (t (error 'api-error :status status :url url :body (body-snippet body)))))))
