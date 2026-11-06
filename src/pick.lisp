(in-package #:habichuela)

;;; Sources, chosen per day with a seed derived from the date:
;;;   :quicklisp                   the Quicklisp projects list, on any forge we can read
;;;   :github, :gitlab, :codeberg  discovery on that forge, see discover.lisp
;;; A rerun on the same day makes the same choices.

(defparameter *min-stars* 0
  "Minimum stars for Quicklisp projects. Zero: the list is curated already.")
(defparameter *discovery-share* 1/2
  "Share of days that look outside Quicklisp.")
(defparameter *discovery-forges* '((:github . 3) (:gitlab . 1) (:codeberg . 1))
  "Relative odds of each forge on discovery days.")
(defparameter *owner-cooldown-days* 30
  "Do not feature the same owner twice within this many days.")
(defparameter *max-attempts* 40
  "Give up on a source after inspecting this many candidates.")

(defvar *attempts-left* 0)

(defun weighted-choice (alist)
  (let ((r (random (reduce #'+ alist :key #'cdr))))
    (loop for (key . weight) in alist
          do (decf r weight)
          when (< r 0) return key
          finally (return (car (first alist))))))

(defun choose-source (date)
  (let ((*random-state* (seeded-random-state (date-seed date))))
    (if (< (random 1.0) *discovery-share*)
        (weighted-choice *discovery-forges*)
        :quicklisp)))

(defun source-label (source)
  (ecase source
    (:quicklisp "the Quicklisp projects list")
    (:github "GitHub search")
    (:gitlab "GitLab search")
    (:codeberg "Codeberg search")))

(defun forge-display (forge)
  (ecase forge (:github "GitHub") (:gitlab "GitLab") (:codeberg "Codeberg") (:git "other Git hosts")))

(defun fetch-repo (ref)
  "Normalized metadata plus the file listing: (values meta paths truncated)."
  (let* ((meta (fetch-meta ref))
         (branch (jget meta "default_branch" "master")))
    (multiple-value-bind (paths truncated) (fetch-tree ref branch)
      (values meta paths truncated))))

(defun fetch-candidate (ref)
  "Like FETCH-REPO, but NIL when the repository should simply be skipped.
Authentication and rate-limit failures are re-signalled."
  (handler-case (fetch-repo ref)
    (api-not-found ()
      (log-line "  ~a: not found, skipping" (ref-label ref))
      nil)
    (api-error (e)
      (when (member (api-status e) '(401 403 429))
        (error e))
      (log-line "  ~a: ~a, skipping" (ref-label ref) e)
      nil)))

(defun ineligible-reason (meta paths recent-owners min-stars)
  "A short reason when the repository is not worth featuring today, else NIL."
  (let ((stars (or (jget meta "stars") 0))
        (owner (lc (jget meta "owner" ""))))
    (cond ((jget meta "fork") "a fork")
          ((jget meta "mirror") "a mirror")
          ((jget meta "archived") "archived")
          ((jget meta "disabled") "disabled")
          ((blank-p (jget meta "description")) "no description")
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

(defun try-candidates (refs &key date source recent dry-run min-stars
                                 (quicklisp-name (constantly nil)))
  "Inspect REFS in order until one is eligible, spending *ATTEMPTS-LEFT*.
MIN-STARS is a number or a function of the ref. Returns the record or NIL."
  (dolist (ref refs nil)
    (when (<= *attempts-left* 0)
      (return nil))
    (decf *attempts-left*)
    (let ((project (funcall quicklisp-name ref)))
      (log-line "Trying ~a~@[ (Quicklisp project ~a)~]" (ref-label ref) project)
      (multiple-value-bind (meta paths truncated) (fetch-candidate ref)
        (when meta
          (let ((why (ineligible-reason meta paths recent
                                        (if (functionp min-stars) (funcall min-stars ref) min-stars))))
            (if why
                (log-line "  skipped: ~a" why)
                (let ((rec (build-snapshot meta paths truncated
                                           :ref ref :date date :source source
                                           :picked-at (now-iso) :quicklisp-project project)))
                  (emit-record rec date dry-run)
                  (return rec)))))))))

(defun taken-p (ref taken)
  "TAKEN holds lowercased owner/name and host/owner/name strings."
  (or (member (ref-key ref) taken :test #'string=)
      (member (lc (ref-label ref)) taken :test #'string=)))

(defun quicklisp-index (projects)
  "Lowercased owner/name -> Quicklisp project name."
  (let ((index (make-hash-table :test 'equal)))
    (dolist (p projects index)
      (setf (gethash (ref-key (cdr p)) index) (car p)))))

(defun pick-from-quicklisp (&key date taken recent dry-run)
  (let* ((projects (pool-projects))
         (index (quicklisp-index projects))
         (candidates (loop for (nil . ref) in projects
                           unless (taken-p ref taken) collect ref)))
    (log-line "Quicklisp: ~d projects (~{~a~^, ~}), ~d featured or excluded, ~d candidates"
              (length projects)
              (loop for (forge . n) in (pool-summary projects)
                    collect (format nil "~d on ~a" n (forge-display forge)))
              (- (length projects) (length candidates)) (length candidates))
    (try-candidates (seeded-shuffle candidates (+ (date-seed date) 2))
                    :date date :source "quicklisp" :recent recent :dry-run dry-run
                    :min-stars (lambda (ref) (if (eq (repo-ref-forge ref) :github) *min-stars* 0))
                    :quicklisp-name (lambda (ref) (gethash (ref-key ref) index)))))

(defun pick-from-discovery (forge &key date taken recent dry-run)
  (let* ((seed (date-seed date))
         (index (quicklisp-index (pool-projects))))
    (log-line "~a: Common Lisp repositories not in Quicklisp~@[, at least ~d stars~]"
              (source-label forge) (let ((n (discovery-min-stars forge))) (and (plusp n) n)))
    (dolist (batch (candidate-batches forge date (+ seed 1)) nil)
      (when (<= *attempts-left* 0)
        (return nil))
      (let ((candidates (remove-if (lambda (ref) (or (gethash (ref-key ref) index) (taken-p ref taken)))
                                   (handler-case (funcall batch)
                                     (error (e)
                                       (log-line "  search failed: ~a" e)
                                       nil)))))
        (when candidates
          (let ((rec (handler-case
                         (try-candidates (seeded-shuffle candidates (+ seed 2))
                                         :date date :source (forge-name forge) :recent recent
                                         :dry-run dry-run :min-stars (discovery-min-stars forge))
                       (api-error (e)
                         ;; Rate limited or refused by this forge: leave it alone for today.
                         (if (member (api-status e) '(401 403 429))
                             (progn (log-line "  ~a, leaving ~a for today" e (source-label forge))
                                    (return nil))
                             (error e))))))
            (when rec (return rec))))))))

(defun pick (&key dry-run (date (today)) source)
  "Choose and record the repository for DATE. SOURCE forces :quicklisp, :github, :gitlab
or :codeberg. Returns the record, or NIL if DATE already has one."
  (unless (valid-date-p date)
    (error "Bad date ~s, want YYYY-MM-DD" date))
  (when (probe-file (record-path date))
    (log-line "Already picked for ~a: ~a" date (record-repo (read-json-file (record-path date))))
    (return-from pick nil))
  (unless (env "GITHUB_TOKEN" (env "GH_TOKEN"))
    (log-line "Warning: GITHUB_TOKEN is not set, unauthenticated GitHub requests are limited to 60 per hour"))
  (let* ((records (list-records))
         (taken (append (picked-repos records) (excluded-repos)))
         (recent (recent-owners records date *owner-cooldown-days*))
         (source (or source (choose-source date)))
         (*attempts-left* *max-attempts*))
    (log-line "~a: looking in ~a" date (source-label source))
    (or (unless (eq source :quicklisp)
          (or (pick-from-discovery source :date date :taken taken :recent recent :dry-run dry-run)
              (progn
                (log-line "Nothing eligible from ~a today, falling back to Quicklisp" (source-label source))
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
      (let ((ref (record-ref rec))
            (date (jget rec "date")))
        (handler-case
            (multiple-value-bind (meta paths truncated) (fetch-repo ref)
              (let ((new (build-snapshot meta paths truncated
                                         :ref ref :date date
                                         :source (jget rec "source"
                                                       (if (jget rec "quicklisp_project") "quicklisp" "github"))
                                         :picked-at (jget rec "picked_at" (jget rec "fetched_at"))
                                         :quicklisp-project (jget rec "quicklisp_project"))))
                (log-line "  ~a: ~:d star~:p, pushed ~a" (ref-label ref)
                          (jget new "stars" 0) (date-part (jget new "pushed_at")))
                (unless dry-run (save-record new))))
          (api-not-found ()
            (log-line "  ~a: gone from its forge" (ref-label ref))
            (setf (gethash "missing" rec) t
                  (gethash "fetched_at" rec) (now-iso))
            (unless dry-run (save-record rec)))
          (api-error (e)
            (log-line "  ~a: ~a" (ref-label ref) e)
            (when (member (api-status e) '(401 403 429))
              (log-line "Stopping the refresh here")
              (return-from refresh nil)))
          (error (e)
            (log-line "  ~a: ~a" (ref-label ref) e)))))))
