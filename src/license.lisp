(in-package #:habichuela)

;;; License identification for forges that report none (Codeberg) or only
;;; "Other" (GitHub, for anything outside its list, LLGPL and public-domain
;;; dedications included). Three tiers: the forge's answer, the LICENSE file,
;;; then the :license string of the ASDF system definition. Best effort: a
;;; handful of phrases that identify the licenses Lisp projects actually use.

(defparameter *license-file-names* '("license" "licence" "copying" "unlicense"))

(defparameter *canonical-license-files*
  '("license" "license.md" "license.txt" "licence" "licence.md" "licence.txt" "copying" "copying.txt" "unlicense"))

(defun license-file (paths &optional repo-name)
  "The most likely top-level license file among PATHS, or NIL. Canonical names win, then a
file carrying the project's own name (COPYING.CLSQL), then the shortest name."
  (let* ((candidates (remove-if-not
                      (lambda (p)
                        (and (not (find #\/ p))
                             (let ((n (lc p)))
                               (and (some (lambda (prefix) (starts-with prefix n)) *license-file-names*)
                                    (not (string= n "licenses"))))))
                      paths))
         (project (and repo-name (lc (subseq repo-name (1+ (or (position #\/ repo-name :from-end t) -1)))))))
    (or (find-if (lambda (p) (member (lc p) *canonical-license-files* :test #'string=)) candidates)
        (and project (plusp (length project))
             (find-if (lambda (p) (search project (lc p))) candidates))
        (first (sort (copy-list candidates) #'< :key #'length)))))

(defun asd-file (ref paths)
  "The system definition most likely to carry the project's :license, or NIL."
  (let* ((asds (remove-if-not (lambda (p)
                                (and (equal (file-extension p) "asd")
                                     (not (vendored-p (path-components p)))))
                              paths))
         (top (remove-if (lambda (p) (find #\/ p)) asds))
         (repo (lc (let ((n (repo-ref-name ref))) (subseq n (1+ (position #\/ n :from-end t))))))
         (bare (if (starts-with "cl-" repo) (subseq repo 3) repo)))
    (flet ((named (name list) (find-if (lambda (p) (string= (lc (file-stem (car (last (path-components p))))) name)) list)))
      (or (named repo top) (named bare top)
          (first (sort (copy-list top) #'< :key #'length))
          (named repo asds) (named bare asds)
          (first (sort (copy-list asds) #'< :key #'length))))))

;;; Text matching

(defun normalize-text (text &key (limit 20000))
  "Lowercase, whitespace collapsed, curly quotes straightened, cut at LIMIT characters."
  (with-output-to-string (out)
    (let ((space t))
      (loop for c across text
            for i from 0 below limit
            do (let ((ch (case (char-code c)
                           ((#x2018 #x2019) #\')
                           ((#x201C #x201D) #\")
                           (t (char-downcase c)))))
                 (if (member ch '(#\Space #\Tab #\Newline #\Return #\Page))
                     (unless space (write-char #\Space out) (setf space t))
                     (progn (write-char ch out) (setf space nil))))))))

(defun has (text &rest phrases)
  (every (lambda (p) (search p text)) phrases))

(defun has-any (text &rest phrases)
  (some (lambda (p) (search p text)) phrases))

(defun gnu-version (text family)
  (cond ((has-any text "version 3" "v3" "version3") (format nil "~a-3.0" family))
        ((has-any text "version 2.1" "v2.1") (format nil "~a-2.1" family))
        ((has-any text "version 2" "v2") (format nil "~a-2.0" family))
        (t family)))

(defun gnu-family (text)
  "The GNU license whose title appears first in TEXT, with its version, or NIL.
Earliest wins because the full GPL text mentions the LGPL near its end, and vice versa."
  (let (best best-pos)
    (loop for (title . family) in '(("gnu affero general public license" . "AGPL")
                                    ("gnu lesser general public license" . "LGPL")
                                    ("gnu library general public license" . "LGPL-2.0")
                                    ("gnu general public license" . "GPL"))
          for pos = (search title text)
          when (and pos (or (null best-pos) (< pos best-pos)))
            do (setf best family best-pos pos))
    (when best
      (if (string= best "LGPL-2.0") best (gnu-version text best)))))

(defun spdx-from-token (token)
  (let ((key (lc (string-trim " .,;" token))))
    (cond ((string= key "llgpl") "LLGPL")
          ((cdr (assoc key *spdx-by-gitlab-key* :test #'string=)))
          (t nil))))

(defun identify-license (text)
  "An SPDX-style identifier for the license TEXT, or NIL when it is not recognized."
  (let* ((s (normalize-text text))
         (head (subseq s 0 (min 1500 (length s))))
         (opening (subseq s 0 (min 300 (length s)))))
    (cond
      ;; Explicit identifiers and one-word files.
      ((search "spdx-license-identifier:" s)
       (let* ((start (+ (search "spdx-license-identifier:" s) (length "spdx-license-identifier:")))
              (token (string-trim " " (subseq s start (or (position #\Space s :start (1+ start)) (length s))))))
         (or (spdx-from-token token) (string-upcase token))))
      ((and (< (length s) 40) (spdx-from-token s)))
      ;; Lisp's own license: its preamble sits on top of the LGPL text.
      ((has-any s "lisp lesser general public license" "llgpl") "LLGPL")
      ;; Public-domain dedications, which often carry MIT-style wording as a fallback.
      ((has s "this is free and unencumbered software released into the public domain") "Unlicense")
      ((has-any s "cc0 1.0 universal" "creative commons legal code cc0") "CC0-1.0")
      ((has opening "public domain") "Public domain")
      ;; GNU family, decided on the opening of the file.
      ((gnu-family head))
      ;; Permissive and others, by their distinctive sentences.
      ((has s "apache license") (if (has s "version 2.0") "Apache-2.0" "Apache"))
      ((has s "mozilla public license") (if (has-any s "version 2.0" "v. 2.0" "2.0") "MPL-2.0" "MPL"))
      ((has s "permission is hereby granted, free of charge, to any person obtaining a copy") "MIT")
      ((has s "redistribution and use in source and binary forms")
       (cond ((has s "all advertising materials") "BSD-4-Clause")
             ((has-any s "neither the name" "names of its contributors" "nor the names of") "BSD-3-Clause")
             (t "BSD-2-Clause")))
      ((has s "permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted")
       (if (has s "copyright notice and this permission notice appear in all copies") "ISC" "0BSD"))
      ((has s "permission to use, copy, modify, and distribute this software and its documentation for any purpose, without fee, and without a written agreement is hereby granted")
       "PostgreSQL")
      ((has s "the origin of this software must not be misrepresented") "Zlib")
      ((has s "do what the fuck you want") "WTFPL")
      ((has s "artistic license") (if (has s "2.0") "Artistic-2.0" "Artistic-1.0"))
      ((has s "boost software license") "BSL-1.0")
      ((has s "eclipse public license") (cond ((has s "2.0") "EPL-2.0") ((has s "1.0") "EPL-1.0") (t "EPL")))
      ((has s "european union public licence") "EUPL-1.2")
      ;; Weak signals, for short notices that only name the license.
      ((gnu-family s))
      ((has s "mit license") "MIT")
      ((has-any s "bsd license" "bsd-style license" "bsd licence") "BSD")
      ((has s "public domain") "Public domain")
      (t nil))))

;;; ASDF :license strings

(defun asd-license-string (text)
  "The string literal after :license (or :licence) in a system definition, or NIL."
  (let* ((s (lc text))
         (pos (or (search ":license" s) (search ":licence" s))))
    (when pos
      (let ((q1 (position #\" text :start (+ pos 8))))
        (when q1
          (let ((q2 (position #\" text :start (1+ q1))))
            (when q2 (subseq text (1+ q1) q2))))))))

(defun declaration-tokens (string)
  (remove "" (uiop:split-string (lc string) :separator " ,;:/()[]-_") :test #'string=))

(defun declaration-gnu-version (s family)
  "Version suffixes as written in :license strings: GPLv3, GPL-3.0, LGPL-2.1, GPL v2."
  (cond ((has s "2.1") (format nil "~a-2.1" family))
        ((has s "3") (format nil "~a-3.0" family))
        ((has s "2") (format nil "~a-2.0" family))
        (t family)))

(defun license-from-declaration (string)
  "SPDX-style id for a free-form license name, as found in :license strings."
  (let* ((s (lc (string-trim " " string)))
         (tokens (declaration-tokens s)))
    (flet ((token (&rest names) (some (lambda (n) (member n tokens :test #'string=)) names))
           (prefixed (prefix) (some (lambda (tok) (starts-with prefix tok)) tokens)))
      (cond ((zerop (length s)) nil)
            ((spdx-from-token s))
            ((token "llgpl") "LLGPL")
            ((or (prefixed "agpl") (token "affero")) (declaration-gnu-version s "AGPL"))
            ((prefixed "lgpl") (declaration-gnu-version s "LGPL"))
            ((prefixed "gpl") (declaration-gnu-version s "GPL"))
            ((token "apache") (if (has-any s "2.0" " 2" "-2" "v2") "Apache-2.0" "Apache"))
            ((token "bsd" "freebsd")
             (cond ((has-any s "3-clause" "3 clause" "bsd-3" "bsd3" "new bsd" "modified bsd" "revised") "BSD-3-Clause")
                   ((has-any s "2-clause" "2 clause" "bsd-2" "bsd2" "simplified" "freebsd") "BSD-2-Clause")
                   (t "BSD")))
            ((token "mit" "expat" "x11") "MIT")
            ((token "mpl") "MPL-2.0")
            ((has-any s "public domain" "public-domain" "publicdomain") "Public domain")
            ((token "unlicense") "Unlicense")
            ((token "zlib" "zlib/libpng") "Zlib")
            ((token "isc") "ISC")
            ((token "wtfpl") "WTFPL")
            ((token "cc0") "CC0-1.0")
            ((token "boost" "bsl") "BSL-1.0")
            ((token "artistic") "Artistic-2.0")
            (t (identify-license string))))))

;;; Putting it together

(defun resolve-license (ref meta paths)
  "(values license from). The forge's answer wins when it names one; otherwise the LICENSE
file is read, then the :license of the system definition. FROM is \"forge\", \"file\",
\"asd\" or NIL."
  (let ((forge-license (jget meta "license"))
        (file (license-file paths (repo-ref-name ref)))
        (branch (jget meta "default_branch" "master")))
    (flet ((fetch (path)
             (handler-case (read-repo-file ref branch path)
               (error (e) (log-line "  could not read ~a: ~a" path e) nil))))
      (if (and forge-license (not (equal forge-license "Other")))
          (values forge-license "forge")
          (let ((from-file (and file (let ((text (fetch file))) (and text (identify-license text))))))
            (if from-file
                (values from-file "file")
                (let* ((asd (asd-file ref paths))
                       (declaration (and asd (let ((text (fetch asd))) (and text (asd-license-string text)))))
                       (from-asd (and declaration (license-from-declaration declaration))))
                  (cond (from-asd (values from-asd "asd"))
                        (file (values "see repository" "file"))
                        (forge-license (values forge-license "forge"))
                        (t (values nil nil))))))))))
