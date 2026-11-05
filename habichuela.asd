(defsystem "habichuela"
  :description "A Common Lisp repository a day: picks a repo, records its stats, builds a static site."
  :author "Julio Jimenez"
  :version "0.1.0"
  :depends-on ("alexandria" "com.inuoe.jzon" "local-time" "spinneret")
  :pathname "src/"
  :serial t
  :components ((:file "package")
               (:file "util")
               (:file "store")
               (:file "github")
               (:file "pool")
               (:file "discover")
               (:file "stats")
               (:file "pick")
               (:file "site")
               (:file "cli")))
