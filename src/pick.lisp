(in-package #:habichuela)

;;; Two sources, chosen per day with a seed derived from the date:
;;;   :quicklisp  the Quicklisp projects list (curated; GitHub-hosted entries only)
;;;   :github     GitHub search for Common Lisp repositories that are not in Quicklisp
;;; A rerun on the same day makes the same choices.

(defparameter *min-stars* 2
  "Skip Quicklisp repositories with fewer stars than this.")
(defparameter *discovery-share* 1/2
  "Share of days that look outside Quicklisp through GitHub search.")
(defparameter *owner-cooldown-days* 30
  "Do not feature the same owner twice within this many days.")
(defparameter *max-attempts* 40
  "Give up on a source after inspecting this many candidates.")

(defvar *attempts-left* 0)

(defun seeded-random-state (seed)
  #+sbcl (sb-ext:seed-random-state seed)
  #-sbcl (make-random-state t))

(defun seeded-shuffle (list seed)
  "Shuffle LIST deterministically from SEED."
  (let ((*random-state* (seeded-random-state seed)))
    (alex:shuffle (copy-list list))))

(defun choose-source (date)
  (let ((*random-state* (seeded-random-state (date-seed date))))
    (if (< (random 1.0) *discovery-share*) :github :quicklisp)))

(defun fetch-repo (repo)
  "Repository JSON plus its file listing: (values meta paths truncated)."
  (let* ((meta (gh-repo repo))
         (branch (jget meta "default_branch" "master")))
    (multiple-value-bind (paths truncated) (gh-tree (jget meta "full_name" repo) branch)
      (values meta paths truncated))))

(defun fetch-candidate (repo)
  "Like FETCH-REPO, but NIL when the repository should simply be skipped.
Authentication and rate-limit failures are re-signalled."
  (handler-case (fetch-repo repo)
    (gh-not-found ()
      (log-line "  ~a: not on GitHub any more, skipping" repo)
      nil)
    (gh-error (e)
      (when (member (gh-status e) '(401 403 429))
        (error e))
      (log-line "  ~a: ~a, skipping" repo e)
      nil)))

(defun ineligible-reason (meta paths recent-owners min-stars)
  "A short reason when the repository is not worth featuring today, else NIL."
  (let ((stars (jget meta "stargazers_count" 0))
        (owner (lc (jget (jget meta "owner") "login" ""))))
    (cond ((truthy (jget meta "fork")) "a fork")
          ((truthy (jget meta "archived")) "archived")
          ((truthy (jget meta "disabled")) "disabled")
          ((blank-p (jget meta "description")) "no description")
          ((not (has-readme-p paths)) "no README")
          ((< stars min-stars) (format nil "only ~d star~:p" stars))
          ((member owner recent-owners :test #'string=)
           (format nil "~a was featured in the last ~d days" owner *owner-cooldown-days*)))))

(defun emit-record (rec date dry-run)
  (cond (dry-run
         (log-line "Dry run, nothing written. The pick for ~a would be:" date)
         (jzon:stringify rec :stream *standard-output* :pretty t)
         (terpri))
        (t
         (save-record rec)
         (log-line "Picked ~a for ~a, wrote ~a" (record-repo rec) date (record-path date)))))

(defun try-candidates (repos &key date source recent dry-run
                                  (min-stars *min-stars*) (quicklisp-name (constantly nil)))
  "Inspect REPOS in order until one is eligible, spending *ATTEMPTS-LEFT*. Returns the record or NIL."
  (dolist (repo repos nil)
    (when (<= *attempts-left* 0)
      (return nil))
    (decf *attempts-left*)
    (let ((project (funcall quicklisp-name repo)))
      (log-line "Trying ~a~@[ (Quicklisp project ~a)~]" repo project)
      (multiple-value-bind (meta paths truncated) (fetch-candidate repo)
        (when meta
          (let ((why (ineligible-reason meta paths recent min-stars)))
            (if why
                (log-line "  skipped: ~a" why)
                (let ((rec (build-snapshot meta paths truncated
                                           :date date :source source :picked-at (now-iso)
                                           :quicklisp-project project)))
                  (emit-record rec date dry-run)
                  (return rec)))))))))

(defun quicklisp-index ()
  "Lowercased owner/name -> Quicklisp project name, for every GitHub-hosted project."
  (let ((index (make-hash-table :test 'equal)))
    (dolist (p (pool-projects) index)
      (setf (gethash (lc (cdr p)) index) (car p)))))

(defun pick-from-quicklisp (&key date taken recent dry-run)
  (let* ((projects (pool-projects))
         (index (make-hash-table :test 'equal))
         (candidates (loop for (project . repo) in projects
                           do (setf (gethash (lc repo) index) project)
                           unless (member (lc repo) taken :test #'string=)
                             collect repo)))
    (log-line "Quicklisp: ~d GitHub-hosted projects, ~d featured or excluded, ~d candidates"
              (length projects) (- (length projects) (length candidates)) (length candidates))
    (try-candidates (seeded-shuffle candidates (+ (date-seed date) 2))
                    :date date :source "quicklisp" :recent recent :dry-run dry-run
                    :quicklisp-name (lambda (repo) (gethash (lc repo) index)))))

(defun pick-from-github (&key date taken recent dry-run)
  (let* ((seed (date-seed date))
         (in-quicklisp (quicklisp-index))
         (windows (seeded-shuffle (month-windows date) (+ seed 1))))
    (log-line "GitHub search: Common Lisp repositories with at least ~d stars that are not in Quicklisp"
              *discovery-min-stars*)
    (loop for window in windows
          for tried from 1 to *discovery-max-windows*
          while (plusp *attempts-left*)
          do (let ((candidates (remove-if (lambda (repo)
                                            (or (gethash (lc repo) in-quicklisp)
                                                (member (lc repo) taken :test #'string=)))
                                          (search-window window))))
               (when candidates
                 (let ((rec (try-candidates (seeded-shuffle candidates (+ seed 2))
                                            :date date :source "github" :recent recent
                                            :dry-run dry-run :min-stars *discovery-min-stars*)))
                   (when rec (return rec))))))))

(defun pick (&key dry-run (date (today)) source)
  "Choose and record the repository for DATE. SOURCE forces :quicklisp or :github.
Returns the record, or NIL if DATE already has one."
  (unless (valid-date-p date)
    (error "Bad date ~s, want YYYY-MM-DD" date))
  (when (probe-file (record-path date))
    (log-line "Already picked for ~a: ~a" date (record-repo (read-json-file (record-path date))))
    (return-from pick nil))
  (unless (gh-token)
    (log-line "Warning: GITHUB_TOKEN is not set, unauthenticated requests are limited to 60 per hour"))
  (let* ((records (list-records))
         (taken (append (picked-repos records) (excluded-repos)))
         (recent (recent-owners records date *owner-cooldown-days*))
         (source (or source (choose-source date)))
         (*attempts-left* *max-attempts*))
    (log-line "~a: looking in ~a" date
              (if (eq source :github) "GitHub search" "the Quicklisp projects list"))
    (or (when (eq source :github)
          (or (pick-from-github :date date :taken taken :recent recent :dry-run dry-run)
              (progn
                (log-line "Nothing eligible from GitHub search today, falling back to Quicklisp")
                (setf *attempts-left* *max-attempts*)
                nil)))
        (pick-from-quicklisp :date date :taken taken :recent recent :dry-run dry-run)
        (error "No eligible repository found after ~d attempts" *max-attempts*))))

(defun refresh (&key (limit 25) dry-run)
  "Re-fetch stats for the LIMIT least recently refreshed records. Never fails the run:
problems are logged, and the refresh stops early on authentication or rate-limit errors."
  (let* ((records (sort (list-records) #'string<
                        :key (lambda (r) (jget r "fetched_at" ""))))
         (batch (subseq records 0 (min limit (length records)))))
    (log-line "Refreshing ~d of ~d record~:p" (length batch) (length records))
    (dolist (rec batch)
      (let ((repo (record-repo rec))
            (date (jget rec "date")))
        (handler-case
            (multiple-value-bind (meta paths truncated) (fetch-repo repo)
              (let ((new (build-snapshot meta paths truncated
                                         :date date
                                         :source (jget rec "source"
                                                       (if (jget rec "quicklisp_project") "quicklisp" "github"))
                                         :picked-at (jget rec "picked_at" (jget rec "fetched_at"))
                                         :quicklisp-project (jget rec "quicklisp_project"))))
                (log-line "  ~a: ~:d star~:p, pushed ~a" repo
                          (jget new "stars" 0) (date-part (jget new "pushed_at")))
                (unless dry-run (save-record new))))
          (gh-not-found ()
            (log-line "  ~a: not on GitHub any more" repo)
            (setf (gethash "missing" rec) t
                  (gethash "fetched_at" rec) (now-iso))
            (unless dry-run (save-record rec)))
          (gh-error (e)
            (log-line "  ~a: ~a" repo e)
            (when (member (gh-status e) '(401 403 429))
              (log-line "Stopping the refresh here")
              (return-from refresh nil)))
          (error (e)
            (log-line "  ~a: ~a" repo e)))))))
