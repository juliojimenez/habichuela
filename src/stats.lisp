(in-package #:habichuela)

;;; Heuristics over the repository file listing.

(defparameter *test-dir-names* '("t" "test" "tests"))
(defparameter *test-stems* '("test" "tests" "run-tests" "run-test" "test-suite" "unit-tests"))
(defparameter *test-suffixes* '("-test" "-tests" ".test" ".tests" "_test" "_tests"))
(defparameter *vendor-dir-names*
  '("ocicl" "quicklisp" ".qlot" "vendor" "deps" "third-party" "third_party" "node_modules" "_build"))
(defparameter *ci-markers*
  '(".github/workflows/" ".gitlab-ci.yml" ".travis.yml" ".circleci/" ".drone.yml"
    ".woodpecker.yml" ".woodpecker/" ".cirrus.yml" ".builds/" "azure-pipelines.yml"
    "appveyor.yml" ".appveyor.yml" "Jenkinsfile" ".buildkite/" "bitbucket-pipelines.yml"))

(defun path-components (path)
  (remove "" (uiop:split-string path :separator "/") :test #'string=))

(defun file-stem (name)
  (let ((dot (position #\. name :from-end t)))
    (if (and dot (plusp dot)) (subseq name 0 dot) name)))

(defun file-extension (name)
  (let ((dot (position #\. name :from-end t)))
    (when (and dot (plusp dot)) (lc (subseq name (1+ dot))))))

(defun vendored-p (components)
  "True when a directory component looks like vendored dependencies."
  (some (lambda (c) (member (lc c) *vendor-dir-names* :test #'string=))
        (butlast components)))

(defun test-file-p (name)
  (let ((stem (lc (file-stem name))))
    (or (member stem *test-stems* :test #'string=)
        (some (lambda (suffix) (ends-with suffix stem)) *test-suffixes*))))

(defun has-tests-p (paths)
  (not (null (some (lambda (p)
          (let ((comps (path-components p)))
            (and comps
                 (not (vendored-p comps))
                 (or (some (lambda (c) (member (lc c) *test-dir-names* :test #'string=)) comps)
                     (test-file-p (car (last comps)))))))
        paths))))

(defun has-ci-p (paths)
  (some (lambda (p)
          (some (lambda (marker)
                  (if (ends-with "/" marker)
                      (starts-with marker (concatenate 'string p "/"))
                      (string= p marker)))
                *ci-markers*))
        paths))

(defun asd-systems (paths)
  (sort (remove-duplicates
         (loop for p in paths
               for comps = (path-components p)
               for name = (car (last comps))
               when (and name (equal (file-extension name) "asd") (not (vendored-p comps)))
                 collect (file-stem name))
         :test #'string=)
        #'string<))

(defun has-readme-p (paths)
  (some (lambda (p) (and (not (find #\/ p)) (starts-with "readme" (lc p)))) paths))

(defun license-id (meta)
  (let ((lic (jget meta "license")))
    (when (hash-table-p lic)
      (let ((spdx (jget lic "spdx_id")))
        (if (or (blank-p spdx) (string= spdx "NOASSERTION"))
            (jget lic "name" "Other")
            spdx)))))

(defun build-snapshot (meta paths truncated &key date source picked-at quicklisp-project)
  "A record for the repository described by META (GitHub repo JSON) and PATHS (its tree)."
  (record "date" date
          "repo" (jget meta "full_name")
          "url" (jget meta "html_url")
          "description" (json-or-null (let ((d (jget meta "description"))) (unless (blank-p d) d)))
          "homepage" (json-or-null (let ((h (jget meta "homepage"))) (unless (blank-p h) h)))
          "language" (json-or-null (jget meta "language"))
          "license" (json-or-null (license-id meta))
          "stars" (jget meta "stargazers_count" 0)
          "forks" (jget meta "forks_count" 0)
          "open_issues" (jget meta "open_issues_count" 0)
          "created_at" (json-or-null (jget meta "created_at"))
          "pushed_at" (json-or-null (jget meta "pushed_at"))
          "archived" (json-bool (truthy (jget meta "archived")))
          "fork" (json-bool (truthy (jget meta "fork")))
          "default_branch" (json-or-null (jget meta "default_branch"))
          "topics" (coerce (to-list (jget meta "topics")) 'vector)
          "has_readme" (json-bool (has-readme-p paths))
          "has_tests" (json-bool (has-tests-p paths))
          "has_ci" (json-bool (has-ci-p paths))
          "asd_systems" (coerce (asd-systems paths) 'vector)
          "tree_truncated" (json-bool truncated)
          "quicklisp_project" (json-or-null quicklisp-project)
          "source" (json-or-null source)
          "picked_at" (json-or-null picked-at)
          "fetched_at" (now-iso)))
