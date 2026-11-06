(in-package #:habichuela)

;;; Discovery outside Quicklisp. Each forge has its own way to find Common Lisp
;;; repositories; all of them produce REPO-REFs in batches, and the picker tries
;;; the batches in order until something is eligible.
;;;
;;;   GitHub    repository search, one random month of creation dates at a time
;;;             (search returns at most 1000 results per query, hence the slices)
;;;   GitLab    the common-lisp topic plus a name/description search for "lisp"
;;;             restricted to projects that use Common Lisp (one seeded page of
;;;             the most recently active); GitLab's language filter alone times
;;;             out for all but the biggest languages (#5), so a keyword-only
;;;             search in a random month of activity is the fallback.
;;;   Codeberg  the common-lisp topic plus a name/description search, both
;;;             filtered on the primary language reported by the API

(defparameter *discovery-min-stars* '((:github . 0) (:gitlab . 0) (:codeberg . 0))
  "Minimum stars for repositories found through search, per forge. Zero: a repository
with a description, a README and Common Lisp as its language is worth a look whatever
its star count. Raise a forge's entry to filter.")
(defparameter *discovery-max-windows* 8
  "GitHub: months to search before giving up on discovery for the day.")
(defparameter *codeberg-search-pages* 3
  "Codeberg: pages of 50 to fetch per search channel.")
(defparameter *gitlab-search-pages* 6
  "GitLab: the language-filtered search is sampled from this many pages of 100, most
recently active first. Deeper pages approach gitlab.com's 15 second statement timeout.")

(defun discovery-min-stars (forge)
  (or (cdr (assoc forge *discovery-min-stars*)) 0))

;;; Month windows

(defun month-windows (date &key (from-year 2008))
  "(year . month) for every month from FROM-YEAR-01 up to the month of DATE."
  (let ((end-year (parse-integer date :start 0 :end 4))
        (end-month (parse-integer date :start 5 :end 7)))
    (loop for year from from-year to end-year
          append (loop for month from 1 to (if (= year end-year) end-month 12)
                       collect (cons year month)))))

(defun month-start (year month)
  (format nil "~4,'0d-~2,'0d-01" year month))

(defun next-month-start (year month)
  (if (= month 12)
      (month-start (1+ year) 1)
      (month-start year (1+ month))))

(defun month-end (year month)
  (let ((days (if (= month 12)
                  31
                  (floor (- (encode-universal-time 0 0 0 1 (1+ month) year 0)
                            (encode-universal-time 0 0 0 1 month year 0))
                         86400))))
    (format nil "~4,'0d-~2,'0d-~2,'0d" year month days)))

;;; GitHub

(defun github-search (query)
  (let ((j (api-get (format nil "https://api.github.com/search/repositories?q=~a&sort=updated&order=desc&per_page=100"
                            (url-encode query))
                    :headers (forge-headers :github))))
    (log-line "  GitHub ~a: ~d repositor~:@p~:[~; (incomplete results)~]"
              query (jget j "total_count" 0) (jget j "total_count" 0) (truthy (jget j "incomplete_results")))
    (mapcar (lambda (item) (make-repo-ref :github "github.com" (jget item "full_name")))
            (to-list (jget j "items")))))

(defun github-window-query (year month)
  (format nil "language:\"Common Lisp\"~@[ stars:>=~d~] fork:false archived:false created:~a..~a"
          (let ((n (discovery-min-stars :github))) (and (plusp n) n))
          (month-start year month) (month-end year month)))

;;; GitLab

(defun gitlab-list (params &key (retries 2))
  "Projects from gitlab.com matching PARAMS, pre-filtered on what the listing shows."
  (let ((projects (to-list (api-get (format nil "https://gitlab.com/api/v4/projects?~a" params)
                                    :headers (forge-headers :gitlab) :retries retries))))
    (log-line "  GitLab ~a: ~d project~:p" params (length projects) (length projects))
    (loop for p in projects
          when (and (>= (jget p "star_count" 0) (discovery-min-stars :gitlab))
                    (not (blank-p (jget p "description")))
                    (null (jget p "forked_from_project")))
            collect (make-repo-ref :gitlab "gitlab.com" (jget p "path_with_namespace")))))

(defun gitlab-language-params (page)
  "Projects that use Common Lisp and mention lisp in name, path or description.
The language filter on its own times out (#5); combined with a search it answers in a second."
  (format nil "search=lisp&search_namespaces=false&with_programming_language=Common%20Lisp&archived=false&order_by=last_activity_at&sort=desc&per_page=100&page=~d"
          page))

(defun gitlab-window-params (year month)
  (format nil "search=lisp&search_namespaces=false&archived=false&order_by=last_activity_at&sort=desc&per_page=100&last_activity_after=~aT00:00:00Z&last_activity_before=~aT00:00:00Z"
          (month-start year month) (next-month-start year month)))

;;; Codeberg

(defun codeberg-search (params)
  "(values refs raw-count): Common Lisp repositories from one page of a Codeberg search."
  (let* ((j (api-get (format nil "https://codeberg.org/api/v1/repos/search?~a" params)
                     :headers (forge-headers :codeberg)))
         (data (to-list (jget j "data"))))
    (values (loop for r in data
                  when (and (equal (jget r "language") "Common Lisp")
                            (>= (jget r "stars_count" 0) (discovery-min-stars :codeberg))
                            (not (truthy (jget r "fork")))
                            (not (truthy (jget r "mirror")))
                            (not (truthy (jget r "archived")))
                            (not (blank-p (jget r "description"))))
                    collect (make-repo-ref :codeberg "codeberg.org" (jget r "full_name")))
            (length data))))

(defun codeberg-channel (base-params)
  (loop with refs = '()
        for page from 1 to *codeberg-search-pages*
        do (multiple-value-bind (batch raw) (codeberg-search (format nil "~a&limit=50&page=~d" base-params page))
             (setf refs (append refs batch))
             (when (< raw 50) (loop-finish)))
        finally (return refs)))

(defun codeberg-candidates ()
  (let ((refs (append (codeberg-channel "q=common-lisp&topic=true&mode=source")
                      (codeberg-channel "q=lisp&includeDesc=true&mode=source&sort=updated&order=desc"))))
    (log-line "  Codeberg: ~d Common Lisp repositor~:@p across both searches" (length refs) (length refs))
    (remove-duplicates refs :key #'ref-key :test #'string= :from-end t)))

;;; Batches

(defmacro quietly (form)
  "Evaluate FORM, turning any failure into an empty result with a log line."
  `(handler-case ,form
     (error (e)
       (log-line "  ~a, skipping this channel" e)
       nil)))

(defun candidate-batches (forge date seed)
  "Closures, in the order to try them, each returning a list of REPO-REFs."
  (ecase forge
    (:github
     (loop for (year . month) in (subseq (seeded-shuffle (month-windows date) seed) 0 *discovery-max-windows*)
           collect (let ((y year) (m month))
                     (lambda () (github-search (github-window-query y m))))))
    (:gitlab
     (let ((page (1+ (mod seed *gitlab-search-pages*)))
           (window (first (seeded-shuffle (month-windows date :from-year 2012) seed))))
       (list (lambda ()
               (remove-duplicates
                (append (quietly (gitlab-list "topic=common-lisp&archived=false&per_page=100"))
                        (quietly (gitlab-list (gitlab-language-params page) :retries 0)))
                :key #'ref-key :test #'string= :from-end t))
             (lambda () (gitlab-list (gitlab-window-params (car window) (cdr window)))))))
    (:codeberg
     (list #'codeberg-candidates))))
