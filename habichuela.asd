(defsystem "habichuela"
  :description "A Common Lisp repository a day: picks a repo, records its stats, builds a static site."
  :author "Julio Jimenez"
  :version "0.2.0"
  :depends-on ("alexandria" "com.inuoe.jzon" "local-time" "spinneret")
  :pathname "src/"
  :serial t
  :components ((:file "package")
               (:file "util")
               (:file "store")
               (:file "http")
               (:file "forges")
               (:file "pool")
               (:file "discover")
               (:file "license")
               (:file "stats")
               (:file "pick")
               (:file "site")
               (:file "cli")))
