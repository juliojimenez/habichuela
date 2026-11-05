(defsystem "habichuela"
  :description "A Common Lisp repository a day: picks a repo, records its stats, builds a static site."
  :author "Julio Jimenez"
  :license "Apache-2.0"
  :version "0.3.0"
  ;; dexador asks for cl+ssl, the OpenSSL binding. pure-tls provides the same API in
  ;; pure Lisp; loading its compatibility layer before anything else and marking cl+ssl
  ;; as already loaded (below) keeps OpenSSL out of the build entirely.
  :defsystem-depends-on ("pure-tls/cl+ssl-compat")
  :depends-on ("alexandria" "babel" "com.inuoe.jzon" "dexador" "local-time" "spinneret")
  :pathname "src/"
  :serial t
  :components ((:file "package")
               (:file "util")
               (:file "store")
               (:file "http")
               (:file "forges")
               (:file "git")
               (:file "pool")
               (:file "discover")
               (:file "license")
               (:file "stats")
               (:file "pick")
               (:file "site")
               (:file "cli")))

(asdf:register-immutable-system "cl+ssl")
