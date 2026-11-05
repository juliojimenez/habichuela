SBCL ?= sbcl
QL_DIST := $(shell cat quicklisp-dist.txt)
QL_DIR := .quicklisp
QL_SETUP := $(QL_DIR)/setup.lisp
SRC := habichuela.asd $(wildcard src/*.lisp)

# Use the gh CLI token locally when GITHUB_TOKEN is not already set.
GITHUB_TOKEN ?= $(shell gh auth token 2>/dev/null)
export GITHUB_TOKEN

.PHONY: deps pool bin pick refresh build serve clean distclean

## deps: install a project-local Quicklisp pinned to the dist in quicklisp-dist.txt
deps: $(QL_SETUP)

$(QL_SETUP):
	mkdir -p build
	curl -fsSL -o build/quicklisp.lisp https://beta.quicklisp.org/quicklisp.lisp
	$(SBCL) --non-interactive --no-userinit --load build/quicklisp.lisp \
	  --eval '(quicklisp-quickstart:install :path "$(QL_DIR)/" :dist-url "http://beta.quicklisp.org/dist/quicklisp/$(QL_DIST)/distinfo.txt")'

## pool: fetch or update the Quicklisp projects list (the candidate pool)
pool:
	@if [ -d build/quicklisp-projects/.git ]; then \
	  git -C build/quicklisp-projects pull -q --ff-only; \
	else \
	  mkdir -p build && git clone -q --depth 1 https://github.com/quicklisp/quicklisp-projects.git build/quicklisp-projects; \
	fi
	@echo "pool: $$(ls build/quicklisp-projects/projects | wc -l | tr -d ' ') Quicklisp projects"

## bin: build the bin/habichuela executable
bin: bin/habichuela

bin/habichuela: $(SRC) $(QL_SETUP)
	mkdir -p bin
	$(SBCL) --non-interactive --no-userinit --load $(QL_SETUP) \
	  --eval '(push (uiop:getcwd) asdf:*central-registry*)' \
	  --eval '(ql:quickload :habichuela :silent t)' \
	  --eval '(habichuela:save-executable "bin/habichuela")'

## pick: choose today's repository (ARGS="--dry-run" to only print it)
pick: bin/habichuela
	bin/habichuela pick $(ARGS)

## refresh: re-fetch stats for the least recently refreshed records
refresh: bin/habichuela
	bin/habichuela refresh $(ARGS)

## build: write the static site to site/
build: bin/habichuela
	bin/habichuela build

## serve: preview the site at http://localhost:8000/
serve: build
	python3 -m http.server --directory site 8000

clean:
	rm -rf bin site

distclean: clean
	rm -rf $(QL_DIR) build
