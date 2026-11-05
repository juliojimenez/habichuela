(in-package #:habichuela)

;;; The forges we can read: GitHub, GitLab (gitlab.com and other instances) and
;;; Codeberg. Each yields the same normalized repository metadata, so nothing
;;; else in the program looks at a forge-specific JSON shape.

(defstruct (repo-ref (:constructor make-repo-ref (forge host name)))
  forge   ; :github, :gitlab or :codeberg
  host    ; "github.com", "gitlab.com", "codeberg.org", ...
  name)   ; "owner/name"; GitLab may nest: "group/subgroup/name"

(defun ref-key (ref)
  "Key for 'already featured' checks: owner/name, lowercased, forge-independent,
so a project mirrored on two forges is featured once."
  (lc (repo-ref-name ref)))

(defun ref-owner (ref)
  (let ((n (repo-ref-name ref)))
    (subseq n 0 (position #\/ n))))

(defun ref-label (ref)
  (if (eq (repo-ref-forge ref) :github)
      (repo-ref-name ref)
      (format nil "~a/~a" (repo-ref-host ref) (repo-ref-name ref))))

(defun forge-name (forge) (string-downcase (symbol-name forge)))

(defparameter *unreachable-hosts* '("gitlab.common-lisp.net")
  "Forge hosts whose API we cannot use. gitlab.common-lisp.net answers every
request, API included, with an anti-bot challenge page.")

(defun forge-for-host (host)
  (let ((h (lc host)))
    (cond ((member h *unreachable-hosts* :test #'string=) nil)
          ((string= h "github.com") :github)
          ((string= h "codeberg.org") :codeberg)
          ((or (string= h "gitlab.com") (starts-with "gitlab." h)) :gitlab))))

(defun split-host-and-path (string)
  "(values host path) for the first https://host/path or git@host:path in STRING."
  (let ((scheme (search "://" string)))
    (if scheme
        (let* ((start (+ scheme 3))
               (slash (position #\/ string :start start)))
          (when slash
            (values (subseq string start slash) (subseq string (1+ slash)))))
        (let ((at (search "git@" string)))
          (when at
            (let ((colon (position #\: string :start at)))
              (when colon
                (values (subseq string (+ at 4) colon) (subseq string (1+ colon))))))))))

(defun parse-repo-url (string)
  "A REPO-REF for the repository URL in STRING, or NIL when the host is not a forge we read."
  (multiple-value-bind (host path) (split-host-and-path string)
    (let ((forge (and host (forge-for-host host))))
      (when forge
        (let* ((end (position-if (lambda (c) (member c '(#\Space #\Tab #\Return))) path))
               (parts (remove "" (uiop:split-string (subseq path 0 end) :separator "/") :test #'string=))
               ;; GitLab web paths continue with /-/tree/..., and nested groups are allowed.
               (parts (if (eq forge :gitlab)
                          (subseq parts 0 (or (position "-" parts :test #'string=) (length parts)))
                          (subseq parts 0 (min 2 (length parts))))))
          (when (>= (length parts) 2)
            (let ((last (car (last parts))))
              (when (ends-with ".git" last)
                (setf last (subseq last 0 (- (length last) 4))))
              (when (plusp (length last))
                (make-repo-ref forge (lc host)
                               (format nil "~{~a~^/~}" (append (butlast parts) (list last))))))))))))

;;; Requests

(defun forge-headers (forge)
  (ecase forge
    (:github
     (append '(("Accept" . "application/vnd.github+json")
               ("X-GitHub-Api-Version" . "2022-11-28")
               ("User-Agent" . "habichuela"))
             (alex:when-let (token (env "GITHUB_TOKEN" (env "GH_TOKEN")))
               (list (cons "Authorization" (format nil "Bearer ~a" token))))))
    (:gitlab
     (append '(("User-Agent" . "habichuela"))
             (alex:when-let (token (env "GITLAB_TOKEN"))
               (list (cons "PRIVATE-TOKEN" token)))))
    (:codeberg
     (append '(("User-Agent" . "habichuela") ("Accept" . "application/json"))
             (alex:when-let (token (env "CODEBERG_TOKEN"))
               (list (cons "Authorization" (format nil "token ~a" token))))))))

(defun api-url (forge host path)
  (ecase forge
    (:github (format nil "https://api.github.com~a" path))
    (:gitlab (format nil "https://~a/api/v4~a" host path))
    (:codeberg (format nil "https://~a/api/v1~a" host path))))

(defun forge-get (forge host path)
  (api-get (api-url forge host path) :headers (forge-headers forge)))

(defun ref-get (ref path)
  (forge-get (repo-ref-forge ref) (repo-ref-host ref) path))

;;; GitHub

(defun github-license (j)
  (let ((lic (jget j "license")))
    (when (hash-table-p lic)
      (let ((spdx (jget lic "spdx_id")))
        (if (or (blank-p spdx) (string= spdx "NOASSERTION"))
            (jget lic "name" "Other")
            spdx)))))

(defun github-meta (ref)
  (let ((j (ref-get ref (format nil "/repos/~a" (repo-ref-name ref)))))
    (record "full_name" (jget j "full_name" (repo-ref-name ref))
            "html_url" (jget j "html_url")
            "description" (jget j "description")
            "homepage" (jget j "homepage")
            "language" (jget j "language")
            "license" (github-license j)
            "stars" (jget j "stargazers_count" 0)
            "forks" (jget j "forks_count" 0)
            "open_issues" (jget j "open_issues_count" 0)
            "created_at" (jget j "created_at")
            "pushed_at" (jget j "pushed_at")
            "archived" (truthy (jget j "archived"))
            "fork" (truthy (jget j "fork"))
            "mirror" nil
            "disabled" (truthy (jget j "disabled"))
            "default_branch" (jget j "default_branch" "master")
            "topics" (to-list (jget j "topics"))
            "owner" (jget (jget j "owner") "login" (ref-owner ref)))))

(defun github-tree (ref branch)
  (let ((j (ref-get ref (format nil "/repos/~a/git/trees/~a?recursive=1"
                                (repo-ref-name ref) (url-encode branch)))))
    (values (mapcar (lambda (e) (jget e "path" "")) (to-list (jget j "tree")))
            (truthy (jget j "truncated")))))

;;; GitLab. Without a token the project representation lacks archived, mirror
;;; and open_issues_count; those read as false and 0.

(defparameter *spdx-by-gitlab-key*
  '(("mit" . "MIT") ("apache-2.0" . "Apache-2.0") ("gpl-3.0" . "GPL-3.0") ("gpl-2.0" . "GPL-2.0")
    ("lgpl-3.0" . "LGPL-3.0") ("lgpl-2.1" . "LGPL-2.1") ("agpl-3.0" . "AGPL-3.0")
    ("bsd-3-clause" . "BSD-3-Clause") ("bsd-2-clause" . "BSD-2-Clause") ("mpl-2.0" . "MPL-2.0")
    ("unlicense" . "Unlicense") ("isc" . "ISC") ("cc0-1.0" . "CC0-1.0") ("0bsd" . "0BSD")
    ("zlib" . "Zlib") ("wtfpl" . "WTFPL") ("epl-2.0" . "EPL-2.0") ("artistic-2.0" . "Artistic-2.0")
    ("bsl-1.0" . "BSL-1.0") ("postgresql" . "PostgreSQL") ("eupl-1.2" . "EUPL-1.2")))

(defun gitlab-license (lic)
  (when (hash-table-p lic)
    (let ((key (jget lic "key")))
      (or (cdr (assoc key *spdx-by-gitlab-key* :test #'equal))
          (jget lic "nickname")
          (jget lic "name")))))

(defun top-language (percentages)
  "The language with the largest share in a GitLab /languages map."
  (when (hash-table-p percentages)
    (let (best best-share)
      (maphash (lambda (language share)
                 (when (or (null best-share) (> share best-share))
                   (setf best language best-share share)))
               percentages)
      best)))

(defun gitlab-project (ref)
  (url-encode (repo-ref-name ref)))

(defun gitlab-meta (ref)
  (let* ((j (ref-get ref (format nil "/projects/~a?license=true" (gitlab-project ref))))
         (languages (ignore-errors (ref-get ref (format nil "/projects/~a/languages" (gitlab-project ref))))))
    (record "full_name" (jget j "path_with_namespace" (repo-ref-name ref))
            "html_url" (jget j "web_url")
            "description" (jget j "description")
            "homepage" nil
            "language" (top-language languages)
            "license" (gitlab-license (jget j "license"))
            "stars" (jget j "star_count" 0)
            "forks" (jget j "forks_count" 0)
            "open_issues" (jget j "open_issues_count" 0)
            "created_at" (jget j "created_at")
            "pushed_at" (jget j "last_activity_at")
            "archived" (truthy (jget j "archived"))
            "fork" (not (null (jget j "forked_from_project")))
            "mirror" (truthy (jget j "mirror"))
            "disabled" nil
            "default_branch" (jget j "default_branch" "main")
            "topics" (to-list (jget j "topics"))
            "owner" (jget (jget j "namespace") "path" (ref-owner ref)))))

(defparameter *gitlab-tree-pages* 10)

(defun gitlab-tree (ref branch)
  (loop with paths = '()
        for page from 1 to *gitlab-tree-pages*
        for entries = (to-list (ref-get ref (format nil "/projects/~a/repository/tree?recursive=true&per_page=100&page=~d&ref=~a"
                                                    (gitlab-project ref) page (url-encode branch))))
        do (dolist (e entries) (push (jget e "path" "") paths))
        when (< (length entries) 100)
          return (values (nreverse paths) nil)
        finally (return (values (nreverse paths) t))))

;;; Codeberg (Forgejo)

(defun codeberg-meta (ref)
  (let ((j (ref-get ref (format nil "/repos/~a" (repo-ref-name ref)))))
    (record "full_name" (jget j "full_name" (repo-ref-name ref))
            "html_url" (jget j "html_url")
            "description" (jget j "description")
            "homepage" (jget j "website")
            "language" (jget j "language")
            "license" (first (to-list (jget j "licenses")))
            "stars" (jget j "stars_count" 0)
            "forks" (jget j "forks_count" 0)
            "open_issues" (jget j "open_issues_count" 0)
            "created_at" (jget j "created_at")
            "pushed_at" (jget j "updated_at")
            "archived" (truthy (jget j "archived"))
            "fork" (truthy (jget j "fork"))
            "mirror" (truthy (jget j "mirror"))
            "disabled" nil
            "default_branch" (jget j "default_branch" "main")
            "topics" (to-list (jget j "topics"))
            "owner" (jget (jget j "owner") "login" (ref-owner ref)))))

(defparameter *codeberg-tree-pages* 5)

(defun codeberg-tree (ref branch)
  (loop with paths = '()
        for page from 1 to *codeberg-tree-pages*
        for j = (ref-get ref (format nil "/repos/~a/git/trees/~a?recursive=true&per_page=1000&page=~d"
                                     (repo-ref-name ref) (url-encode branch) page))
        do (dolist (e (to-list (jget j "tree"))) (push (jget e "path" "") paths))
        unless (truthy (jget j "truncated"))
          return (values (nreverse paths) nil)
        finally (return (values (nreverse paths) t))))

;;; Dispatch

(defun fetch-meta (ref)
  "Normalized metadata for REF: full_name, html_url, description, homepage, language,
license, stars, forks, open_issues, created_at, pushed_at, archived, fork, mirror,
disabled, default_branch, topics (a list) and owner."
  (ecase (repo-ref-forge ref)
    (:github (github-meta ref))
    (:gitlab (gitlab-meta ref))
    (:codeberg (codeberg-meta ref))))

(defun fetch-tree (ref branch)
  "Paths of every blob and tree in BRANCH, and whether the listing was cut short."
  (ecase (repo-ref-forge ref)
    (:github (github-tree ref branch))
    (:gitlab (gitlab-tree ref branch))
    (:codeberg (codeberg-tree ref branch))))

;;; Raw files

(defun url-encode-path (path)
  "Percent-encode each segment of PATH, keeping the slashes."
  (format nil "~{~a~^/~}" (mapcar #'url-encode (uiop:split-string path :separator "/"))))

(defun raw-file-url (ref branch path)
  "URL of the raw contents of PATH on BRANCH."
  (let ((host (repo-ref-host ref))
        (name (repo-ref-name ref)))
    (ecase (repo-ref-forge ref)
      (:github (format nil "https://raw.githubusercontent.com/~a/~a/~a"
                       name (url-encode-path branch) (url-encode-path path)))
      (:gitlab (format nil "https://~a/~a/-/raw/~a/~a"
                       host name (url-encode-path branch) (url-encode-path path)))
      (:codeberg (format nil "https://~a/~a/raw/branch/~a/~a"
                         host name (url-encode-path branch) (url-encode-path path))))))
