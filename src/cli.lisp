(in-package #:habichuela)

(defun usage (&optional (stream *standard-output*))
  (format stream "usage: habichuela <command> [options]

commands:
  pick [--dry-run] [--date YYYY-MM-DD] [--source quicklisp|github]
                                         choose the repository for the day and record its stats
  refresh [--limit N] [--dry-run]        re-fetch stats for the N least recently refreshed records (default 25)
  build                                  write the static site to site/
  pool                                   count the candidate pool

environment:
  GITHUB_TOKEN          GitHub API token (strongly recommended)
  HABICHUELA_DATE       override today's date, YYYY-MM-DD
  HABICHUELA_BASE_URL   public URL of the site, used for links in feed.xml
  HABICHUELA_ROOT       project root (default: current directory)
"))

(defun parse-source (s)
  (cond ((null s) nil)
        ((member s (quote ("quicklisp" "ql")) :test (function string-equal)) :quicklisp)
        ((member s (quote ("github" "gh" "search")) :test (function string-equal)) :github)
        (t (error "Unknown source ~s, want quicklisp or github" s))))

(defun flag-p (args name)
  (and (member name args :test #'string=) t))

(defun flag-value (args name default)
  (let ((m (member name args :test #'string=)))
    (if (and m (second m)) (second m) default)))

(defun main (args)
  "Run a command. Returns the process exit code."
  (let ((cmd (first args))
        (rest (rest args)))
    (cond ((null cmd) (usage *error-output*) 2)
          ((string= cmd "pick")
           (pick :dry-run (flag-p rest "--dry-run") :date (flag-value rest "--date" (today))
                 :source (parse-source (flag-value rest "--source" nil)))
           0)
          ((string= cmd "refresh")
           (refresh :limit (parse-integer (flag-value rest "--limit" "25"))
                    :dry-run (flag-p rest "--dry-run"))
           0)
          ((string= cmd "build") (build-site) 0)
          ((string= cmd "pool")
           (format t "~d GitHub-hosted Quicklisp projects~%" (length (pool-projects)))
           0)
          ((member cmd '("help" "--help" "-h") :test #'string=) (usage) 0)
          (t (format *error-output* "unknown command: ~a~%~%" cmd) (usage *error-output*) 2))))

(defun toplevel ()
  "Entry point of the saved executable."
  (sb-ext:disable-debugger)
  (let ((code (handler-case (main (rest sb-ext:*posix-argv*))
                (sb-sys:interactive-interrupt ()
                  (format *error-output* "~&interrupted~%")
                  130)
                (error (e)
                  (format *error-output* "~&error: ~a~%" e)
                  1))))
    (finish-output *standard-output*)
    (finish-output *error-output*)
    (uiop:quit (or code 0))))

(defun save-executable (path)
  (sb-ext:save-lisp-and-die path :executable t :toplevel #'toplevel :save-runtime-options t))
