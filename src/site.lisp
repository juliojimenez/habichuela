(in-package #:habichuela)

(defparameter *site-title* "habichuela")
(defparameter *site-tagline* "A Common Lisp repository a day.")
(defparameter *tag-authority* "habichue.la"
  "Authority for the tag: URIs that identify feed entries. Never changes, even if the site moves.")
(defparameter *socials*
  '(("X" . "https://x.com/habicuela")
    ("Mastodon" . "https://mastodon.social/@habichuela")
    ("Bluesky" . "https://bsky.app/profile/habichue.la")))
(defparameter *logo-file* "bean.png"
  "Logo and favicon, copied from static/ into the site. When the file is missing the
header, favicon and preview image are simply left out.")

(defun static-dir () (merge-pathnames "static/" (root)))
(defun logo-p () (probe-file (merge-pathnames *logo-file* (static-dir))))

(defun base-url ()
  "Public URL of the site with one trailing slash. Used for absolute links in the feed.
The workflow passes the Pages base URL; the default is the custom domain."
  (let ((u (string-right-trim "/" (env "HABICHUELA_BASE_URL" "https://habichue.la"))))
    ;; Pages reports http:// until "Enforce HTTPS" is on; the site is always https.
    (when (starts-with "http://" u)
      (setf u (concatenate 'string "https://" (subseq u 7))))
    (concatenate 'string u "/")))

(defparameter *css* "
:root { --bg:#fbfaf7; --fg:#1f1d1a; --muted:#6b665e; --line:#e4dfd5; --card:#ffffff; --accent:#8b2635; --chip:#f1ede4; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#151412; --fg:#ece7dd; --muted:#a39c90; --line:#2c2924; --card:#1d1b18; --accent:#e5717f; --chip:#262320; }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg); font: 16px/1.5 system-ui, -apple-system, sans-serif; }
header, main, footer { max-width: 72rem; margin: 0 auto; padding: 0 1rem; }
header { padding-top: 2rem; display: flex; flex-wrap: wrap; align-items: center; gap: .5rem 1.25rem; }
header h1 { margin: 0; font-size: 1.75rem; letter-spacing: -.01em; }
header h1 a { color: inherit; text-decoration: none; display: inline-flex; align-items: center; gap: .5rem; }
.logo { height: 2.1rem; width: auto; }
.tagline { margin: 0; color: var(--muted); }
nav { margin-left: auto; display: flex; gap: 1rem; }
a { color: var(--accent); }
.featured { margin: 2rem 0; padding: 1.5rem; background: var(--card); border: 1px solid var(--line); border-radius: 12px; }
.eyebrow { margin: 0 0 .25rem; text-transform: uppercase; letter-spacing: .08em; font-size: .75rem; color: var(--muted); }
.featured h2 { margin: 0 0 .5rem; font-size: 1.6rem; overflow-wrap: anywhere; }
.description { font-size: 1.1rem; margin: .25rem 0 1rem; }
.chips { list-style: none; padding: 0; margin: 0 0 .75rem; display: flex; flex-wrap: wrap; gap: .5rem; }
.chips li { background: var(--chip); border-radius: 999px; padding: .2rem .75rem; font-size: .9rem; }
.chips .warn { background: var(--accent); color: #fff; }
.systems, .topics, .homepage { color: var(--muted); font-size: .95rem; margin: .25rem 0; overflow-wrap: anywhere; }
.table-wrap { overflow-x: auto; }
table { width: 100%; border-collapse: collapse; font-size: .95rem; }
th, td { text-align: left; padding: .6rem .5rem; border-bottom: 1px solid var(--line); vertical-align: top; }
th { color: var(--muted); font-weight: 600; font-size: .8rem; text-transform: uppercase; letter-spacing: .06em; }
td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
td.date { white-space: nowrap; color: var(--muted); }
td.updated { white-space: nowrap; }
.desc, .host { color: var(--muted); font-size: .9rem; }
footer { padding: 2rem 1rem 3rem; color: var(--muted); font-size: .9rem; }
.socials a { margin-right: .15rem; }
@media (max-width: 640px) {
  th:nth-child(n+5), td:nth-child(n+5) { display: none; }
  .tagline { flex-basis: 100%; }
}
@media (max-width: 480px) {
  th:nth-child(4), td:nth-child(4) { display: none; }
}
")

(defun source-text (rec)
  (let ((s (jget rec "source")))
    (cond ((equal s "github") "found by GitHub search")
          ((equal s "gitlab") "found by GitLab search")
          ((equal s "codeberg") "found by Codeberg search")
          (t "from the Quicklisp projects list"))))

(defun other-forge-host (rec)
  "The host when the repository is not on GitHub, else NIL."
  (let ((host (jget rec "host")))
    (when (and host (not (equal host "github.com"))) host)))

(defun yes-no (v) (if (truthy v) "yes" "no"))
(defun fmt-int (n) (format nil "~:d" (if (integerp n) n 0)))

(defun updated-text (iso)
  (let ((d (days-since iso)))
    (if d (format nil "~a (~a)" (date-part iso) (humanize-days d)) "unknown")))

(defun featured-section (rec)
  (spinneret:with-html
    (:section :class "featured"
      (:p :class "eyebrow" (format nil "~a · latest pick · ~a" (jget rec "date") (source-text rec)))
      (:h2 (:a :href (jget rec "url") (jget rec "repo")))
      (:p :class "description" (or (jget rec "description") "No description."))
      (let ((home (jget rec "homepage")))
        (when home (:p :class "homepage" (:a :href home home))))
      (:ul :class "chips"
        (let ((stars (jget rec "stars")))
          (when (integerp stars) (:li (format nil "★ ~a" (fmt-int stars)))))
        (:li (format nil "Updated ~a" (updated-text (jget rec "pushed_at"))))
        (:li (format nil "License: ~a" (or (jget rec "license") "none")))
        (:li (format nil "Tests: ~a" (yes-no (jget rec "has_tests"))))
        (:li (format nil "CI: ~a" (yes-no (jget rec "has_ci"))))
        (let ((issues (jget rec "open_issues")))
          (when (integerp issues) (:li (format nil "Open issues: ~a" (fmt-int issues)))))
        (let ((ql (jget rec "quicklisp_project")))
          (if ql (:li (format nil "Quicklisp: ~a" ql)) (:li "Not in Quicklisp")))
        (let ((host (other-forge-host rec)))
          (when host (:li (format nil "On ~a" host))))
        (when (truthy (jget rec "archived")) (:li :class "warn" "Archived"))
        (when (truthy (jget rec "missing")) (:li :class "warn" "No longer online")))
      (let ((systems (to-list (jget rec "asd_systems"))))
        (when systems (:p :class "systems" (format nil "ASDF systems: ~{~a~^, ~}" systems))))
      (let ((topics (to-list (jget rec "topics"))))
        (when topics (:p :class "topics" (format nil "Topics: ~{~a~^, ~}" topics)))))))

(defun archive-table (records)
  (spinneret:with-html
    (:div :class "table-wrap"
      (:table
        (:thead
          (:tr (:th "Date") (:th "Repository") (:th :class "num" "Stars")
               (:th "Updated") (:th "Tests") (:th "CI") (:th "License") (:th "Quicklisp")))
        (:tbody
          (dolist (r records)
            (:tr :id (jget r "date")
              (:td :class "date" (jget r "date"))
              (:td (:a :href (jget r "url") (jget r "repo"))
                   (let ((host (other-forge-host r)))
                     (when host (:span :class "host" (format nil " · ~a" host))))
                   (:div :class "desc" (or (jget r "description") "")))
              (:td :class "num" (let ((s (jget r "stars"))) (if (integerp s) (fmt-int s) "n/a")))
              (:td :class "updated" :title (or (jget r "pushed_at") "") (date-part (jget r "pushed_at")))
              (:td (yes-no (jget r "has_tests")))
              (:td (yes-no (jget r "has_ci")))
              (:td (or (jget r "license") "none"))
              (:td (if (jget r "quicklisp_project") "yes" "no")))))))))

(defun socials-line ()
  (spinneret:with-html
    (:p :class "socials" "Follow habichuela: "
      (let ((first t))
        (dolist (s *socials*)
          (unless first (:span " · "))
          (setf first nil)
          (:a :href (cdr s) :rel "me" (car s)))))))

(defun index-html (records)
  (let ((latest (first records))
        (logo (logo-p)))
    (spinneret:with-html-string
      (:doctype)
      (:html :lang "en"
        (:head
          (:meta :charset "utf-8")
          (:meta :name "viewport" :content "width=device-width, initial-scale=1")
          (:title *site-title*)
          (:meta :name "description" :content *site-tagline*)
          (:meta :property "og:title" :content *site-title*)
          (:meta :property "og:description" :content *site-tagline*)
          (:meta :property "og:url" :content (base-url))
          (:meta :name "twitter:card" :content "summary")
          (when logo
            (:link :rel "icon" :type "image/png" :href *logo-file*)
            (:link :rel "apple-touch-icon" :href *logo-file*)
            (:meta :property "og:image" :content (concatenate 'string (base-url) *logo-file*)))
          (:link :rel "alternate" :type "application/atom+xml" :title *site-title* :href "feed.xml")
          (:style (:raw *css*)))
        (:body
          (:header
            (:h1 (:a :href "./"
                   (when logo (:img :class "logo" :src *logo-file* :alt "" :width 512 :height 512))
                   *site-title*))
            (:p :class "tagline" *site-tagline*)
            (:nav (:a :href "#archive" "Archive") (:a :href "feed.xml" "Feed") (:a :href "data.json" "JSON")))
          (:main
            (if latest (featured-section latest) (:p "No picks yet."))
            (:section :id "archive"
              (:h2 (format nil "Archive (~d)" (length records)))
              (archive-table records)))
          (:footer
            (socials-line)
            (:p (format nil "Built ~a. Stats come from the GitHub, GitLab and Codeberg APIs and are refreshed a few at a time each day." (now-iso)))))))))

(defun xml-escape (s)
  (with-output-to-string (out)
    (loop for c across (or s "")
          do (case c
               (#\& (write-string "&amp;" out))
               (#\< (write-string "&lt;" out))
               (#\> (write-string "&gt;" out))
               (#\" (write-string "&quot;" out))
               (t (write-char c out))))))

(defun entry-summary (r)
  (format nil "~@[~a ~]~@[★ ~a · ~]updated ~a · license ~a · tests ~a · CI ~a"
          (jget r "description")
          (let ((s (jget r "stars"))) (and (integerp s) (fmt-int s)))
          (date-part (jget r "pushed_at"))
          (or (jget r "license") "none")
          (yes-no (jget r "has_tests"))
          (yes-no (jget r "has_ci"))))

(defun entry-id (r)
  (format nil "tag:~a,~a:pick" *tag-authority* (jget r "date")))

(defun entry-time (r)
  "When the pick was made. Older records without picked_at fall back to midnight UTC of their date."
  (or (jget r "picked_at") (format nil "~aT00:00:00Z" (jget r "date"))))

(defun atom-feed (records)
  (let ((base (base-url))
        (entries (subseq records 0 (min 50 (length records)))))
    (with-output-to-string (out)
      (format out "<?xml version=\"1.0\" encoding=\"utf-8\"?>~%")
      (format out "<feed xmlns=\"http://www.w3.org/2005/Atom\">~%")
      (format out "  <title>~a</title>~%" (xml-escape *site-title*))
      (format out "  <subtitle>~a</subtitle>~%" (xml-escape *site-tagline*))
      (format out "  <link href=\"~a\"/>~%" (xml-escape base))
      (format out "  <link rel=\"self\" href=\"~afeed.xml\"/>~%" (xml-escape base))
      (format out "  <id>tag:~a,2026:feed</id>~%" *tag-authority*)
      (when (logo-p)
        (format out "  <icon>~a~a</icon>~%" (xml-escape base) *logo-file*))
      (format out "  <author><name>~a</name></author>~%" (xml-escape *site-title*))
      (format out "  <updated>~a</updated>~%"
              (if records (entry-time (first records)) (now-iso)))
      (dolist (r entries)
        (format out "  <entry>~%")
        (format out "    <title>~a</title>~%" (xml-escape (jget r "repo")))
        (format out "    <link href=\"~a\"/>~%" (xml-escape (jget r "url")))
        (format out "    <id>~a</id>~%" (entry-id r))
        (format out "    <published>~a</published>~%    <updated>~a</updated>~%" (entry-time r) (entry-time r))
        (format out "    <summary>~a</summary>~%" (xml-escape (entry-summary r)))
        (format out "  </entry>~%"))
      (format out "</feed>~%"))))

(defun build-site ()
  "Write index.html, feed.xml and data.json to site/, and copy everything in static/."
  (let ((records (list-records))
        (dir (site-dir)))
    (ensure-directories-exist dir)
    (write-text-file (merge-pathnames "index.html" dir) (index-html records))
    (write-text-file (merge-pathnames "feed.xml" dir) (atom-feed records))
    (write-json-file (merge-pathnames "data.json" dir) (coerce records 'vector))
    (write-text-file (merge-pathnames ".nojekyll" dir) "")
    (when (probe-file (static-dir))
      (dolist (file (uiop:directory-files (static-dir)))
        (uiop:copy-file file (merge-pathnames (file-namestring file) dir))))
    (log-line "Built the site with ~d record~:p in ~a" (length records) dir)))
