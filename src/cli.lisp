(in-package #:habichuela)

(defun usage (&optional (stream *standard-output*))
  (format stream "usage: habichuela <command> [options]

commands:
  pick [--dry-run] [--date YYYY-MM-DD] [--source quicklisp|github|gitlab|codeberg]
                                         choose the repository for the day and record its stats
  refresh [--limit N] [--dry-run]        re-fetch stats for the N least recently refreshed records (default 25)
  build                                  write the static site to site/
  pool                                   count the Quicklisp candidate pool per forge
  inspect <repo>                         print the record that would be written for one repository
  license <repo>                         show how the license of one repository is determined

<repo> is owner/name for GitHub, or host/owner/name for any forge, or a repository URL.

environment:
  GITHUB_TOKEN          GitHub API token (strongly recommended)
  GITLAB_TOKEN          GitLab token (optional; unlocks archived and issue counts)
  CODEBERG_TOKEN        Codeberg token (optional)
  HABICHUELA_DATE       override today's date, YYYY-MM-DD
  HABICHUELA_BASE_URL   public URL of the site, used for links in feed.xml
  HABICHUELA_ROOT       project root (default: current directory)
"))

(defun parse-source (s)
  (cond ((null s) nil)
        ((member s '("quicklisp" "ql") :test #'string-equal) :quicklisp)
        ((member s '("github" "gh") :test #'string-equal) :github)
        ((member s '("gitlab" "gl") :test #'string-equal) :gitlab)
        ((member s '("codeberg" "cb") :test #'string-equal) :codeberg)
        (t (error "Unknown source ~s, want quicklisp, github, gitlab or codeberg" s))))

(defun target-ref (target)
  "A REPO-REF for a command-line repository argument."
  (unless target
    (error "A repository is required: owner/name, host/owner/name or a URL"))
  (let ((url (cond ((search "://" target) target)
                   ((= (count #\/ target) 1) (format nil "https://github.com/~a" target))
                   (t (format nil "https://~a" target)))))
    (or (parse-repo-url url)
        (error "Not a repository on a forge we read: ~a" target))))

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
           (pick :dry-run (flag-p rest "--dry-run")
                 :date (flag-value rest "--date" (today))
                 :source (parse-source (flag-value rest "--source" nil)))
           0)
          ((string= cmd "refresh")
           (refresh :limit (parse-integer (flag-value rest "--limit" "25"))
                    :dry-run (flag-p rest "--dry-run"))
           0)
          ((string= cmd "build") (build-site) 0)
          ((string= cmd "pool")
           (let ((projects (pool-projects)))
             (format t "~d Quicklisp projects on forges we can read:~%" (length projects))
             (loop for (forge . n) in (sort (pool-summary projects) #'> :key #'cdr)
                   do (format t "  ~6d on ~a~%" n (forge-display forge))))
           0)
          ((string= cmd "inspect")
           (let ((ref (target-ref (first rest))))
             (multiple-value-bind (meta paths truncated) (fetch-repo ref)
               (jzon:stringify (build-snapshot meta paths truncated :ref ref :date (today) :source "inspect")
                               :stream *standard-output* :pretty t)
               (terpri)))
           0)
          ((string= cmd "license")
           (let ((ref (target-ref (first rest))))
             (multiple-value-bind (meta paths) (fetch-repo ref)
               (multiple-value-bind (license from) (resolve-license ref meta paths)
                 (format t "~a~%  forge says:   ~a~%  license file: ~a~%  result:       ~a~@[ (from ~a)~]~%"
                         (ref-label ref) (or (jget meta "license") "none")
                         (or (license-file paths (repo-ref-name ref)) "none") (or license "none") from))))
           0)
          ((member cmd '("help" "--help" "-h") :test #'string=) (usage) 0)
          (t (format *error-output* "unknown command: ~a~%~%" cmd) (usage *error-output*) 2))))

(defun toplevel ()
  "Entry point of the saved executable."
  (sb-ext:disable-debugger)
  (let ((code (unwind-protect
                   (handler-case (main (rest sb-ext:*posix-argv*))
                     (sb-sys:interactive-interrupt ()
                       (format *error-output* "~&interrupted~%")
                       130)
                     (error (e)
                       (format *error-output* "~&error: ~a~%" e)
                       1))
                (cleanup-clones))))
    (finish-output *standard-output*)
    (finish-output *error-output*)
    (uiop:quit (or code 0))))

(defun save-executable (path)
  (sb-ext:save-lisp-and-die path :executable t :toplevel #'toplevel :save-runtime-options t))
