(in-package #:habichuela)

;;; Clone-only forges: hosts whose API we cannot use but whose git we can read.
;;; gitlab.common-lisp.net answers every API call with an anti-bot challenge
;;; page, yet serves git normally. A shallow clone gives the file listing, the
;;; last commit date, the README for a description and the license file; stars,
;;; forks and issue counts stay unknown. Clones live in one temporary directory
;;; per process, deleted at exit.

(defvar *clone-root* nil
  "Directory holding this process's clones.")
(defvar *clones* (make-hash-table :test 'equal)
  "ref-key -> clone directory.")

(defun clone-root ()
  (or *clone-root*
      (setf *clone-root*
            (ensure-directories-exist
             (merge-pathnames (format nil "habichuela-~d-~d/"
                                      (get-universal-time) (random 1000000 (make-random-state t)))
                              (uiop:temporary-directory))))))

(defun cleanup-clones ()
  (when *clone-root*
    (ignore-errors (uiop:delete-directory-tree *clone-root* :validate t :if-does-not-exist :ignore))
    (setf *clone-root* nil)
    (clrhash *clones*)))

(defun git (dir &rest args)
  "Run git in DIR and return its standard output, trimmed."
  (string-right-trim '(#\Newline #\Return)
                     (uiop:run-program (append (list "env" "GIT_TERMINAL_PROMPT=0" "git" "-C" (uiop:native-namestring dir))
                                               args)
                                       :output :string :error-output nil :ignore-error-status t)))

(defun clone-url (ref)
  (format nil "https://~a/~a.git" (repo-ref-host ref) (repo-ref-name ref)))

(defun git-clone (ref)
  "The directory of a shallow clone of REF, cloning on first use.
Signals API-NOT-FOUND when the clone fails, whatever the reason."
  (or (gethash (ref-key ref) *clones*)
      (let ((dir (merge-pathnames (format nil "~a/" (substitute #\- #\/ (repo-ref-name ref))) (clone-root)))
            (url (clone-url ref)))
        (log-line "  cloning ~a" url)
        (multiple-value-bind (out err code)
            (uiop:run-program (list "env" "GIT_TERMINAL_PROMPT=0" "git"
                                    "-c" "http.lowSpeedLimit=1000" "-c" "http.lowSpeedTime=30"
                                    "clone" "--quiet" "--depth" "1" "--single-branch"
                                    url (uiop:native-namestring dir))
                              :output :string :error-output :string :ignore-error-status t)
          (declare (ignore out))
          (unless (zerop code)
            (error 'api-not-found :url url :body (body-snippet (string-trim '(#\Newline) err))))
          (setf (gethash (ref-key ref) *clones*) dir)))))

(defun git-tree (ref branch)
  "Paths of every blob and tree at HEAD of the clone."
  (declare (ignore branch))
  (values (remove "" (uiop:split-string (git (git-clone ref) "ls-tree" "-r" "-t" "--name-only" "HEAD")
                                        :separator '(#\Newline))
                  :test #'string=)
          nil))

;;; README

(defun underline-p (line)
  (and (>= (length line) 3) (every (lambda (c) (find c "=-~*#")) line)))

(defun noise-line-p (line)
  "Headings, badges, directives, markup and tables: not prose."
  (or (underline-p line)
      (some (lambda (prefix) (starts-with prefix line))
            '("#" "*" "[![" "![" "<" "|" ".. " ":" "---" "+++" "```" "~~~" "%" ";"))))

(defun strip-inline-markup (text)
  (remove-if (lambda (c) (find c "`*_")) text))

(defun first-paragraph (text &key (limit 240))
  "The first run of prose lines in TEXT, joined, lightly stripped of markup, cut at LIMIT."
  (let ((paragraph '())
        (in-fence nil))
    (dolist (raw (uiop:split-string text :separator '(#\Newline #\Return)))
      (let ((line (string-trim '(#\Space #\Tab) raw)))
        (cond ((or (starts-with "```" line) (starts-with "~~~" line))
               (setf in-fence (not in-fence))
               (when paragraph (return)))
              (in-fence)
              ((zerop (length line))
               (when paragraph (return)))
              ;; "Title" followed by "=====" is a heading, not prose.
              ((and (underline-p line) (= (length paragraph) 1))
               (setf paragraph '()))
              ((noise-line-p line)
               (when paragraph (return)))
              (t (push line paragraph)))))
    (when paragraph
      (let* ((joined (strip-inline-markup (format nil "~{~a~^ ~}" (nreverse paragraph))))
             (joined (string-trim " " joined)))
        (if (> (length joined) limit)
            (let ((cut (or (position #\Space joined :end limit :from-end t) limit)))
              (concatenate 'string (subseq joined 0 cut) "..."))
            joined)))))

(defun readme-description (dir paths)
  "The first paragraph of the top-level README, or NIL."
  (let ((readme (find-if (lambda (p) (and (not (find #\/ p)) (starts-with "readme" (lc p)))) paths)))
    (when readme
      (let ((text (ignore-errors (uiop:read-file-string (uiop:subpathname dir readme) :external-format :utf-8))))
        (when text
          (let ((paragraph (first-paragraph text)))
            (unless (blank-p paragraph) paragraph)))))))

;;; Metadata

(defun git-meta (ref)
  (let* ((dir (git-clone ref))
         (paths (git-tree ref nil))
         (branch (git dir "rev-parse" "--abbrev-ref" "HEAD"))
         (pushed (git dir "log" "-1" "--format=%cI")))
    (record "full_name" (repo-ref-name ref)
            "html_url" (format nil "https://~a/~a" (repo-ref-host ref) (repo-ref-name ref))
            "description" (readme-description dir paths)
            "homepage" nil
            "language" (when (some (lambda (p) (ends-with ".lisp" (lc p))) paths) "Common Lisp")
            "license" nil
            "stars" nil
            "forks" nil
            "open_issues" nil
            "created_at" nil
            "pushed_at" (unless (blank-p pushed) pushed)
            "archived" nil
            "fork" nil
            "mirror" nil
            "disabled" nil
            "default_branch" (if (blank-p branch) "HEAD" branch)
            "topics" nil
            "owner" (ref-owner ref))))

;;; Dispatch over every forge kind

(defun fetch-meta (ref)
  "Normalized metadata for REF: full_name, html_url, description, homepage, language,
license, stars, forks, open_issues, created_at, pushed_at, archived, fork, mirror,
disabled, default_branch, topics (a list) and owner. Counts are NIL when unknown."
  (ecase (repo-ref-forge ref)
    (:github (github-meta ref))
    (:gitlab (gitlab-meta ref))
    (:codeberg (codeberg-meta ref))
    (:git (git-meta ref))))

(defun fetch-tree (ref branch)
  "Paths of every blob and tree in BRANCH, and whether the listing was cut short."
  (ecase (repo-ref-forge ref)
    (:github (github-tree ref branch))
    (:gitlab (gitlab-tree ref branch))
    (:codeberg (codeberg-tree ref branch))
    (:git (git-tree ref branch))))

(defun read-repo-file (ref branch path)
  "Contents of PATH on BRANCH as a string, or NIL when it does not exist."
  (if (eq (repo-ref-forge ref) :git)
      (let ((file (uiop:subpathname (git-clone ref) path)))
        (when (probe-file file)
          (uiop:read-file-string file :external-format :utf-8)))
      (fetch-text (raw-file-url ref branch path))))
