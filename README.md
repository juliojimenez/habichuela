# habichuela

A Common Lisp repository a day, at [habichue.la](https://habichue.la/). Every
day a GitHub Actions job picks one Common Lisp repository, records its stats
(stars, last update, license, whether it has tests and CI, ASDF systems), and
rebuilds a static site with the archive of every pick plus an Atom feed.

Picks come from four sources, chosen per day:

- **Quicklisp**, about half the days: the Quicklisp projects list, a curated
  set of roughly 2,000 libraries, wherever they are hosted among the forges
  below.
- **GitHub search**, **GitLab search** and **Codeberg search**, the other half,
  with odds of 3:1:1: repositories whose primary language is Common Lisp and
  that are *not* in Quicklisp.

Three forges are read through their APIs: GitHub, GitLab (gitlab.com) and
Codeberg. gitlab.common-lisp.net, home to 84 Quicklisp projects, blocks API
calls with an anti-bot challenge but serves git, so its projects are read from
a shallow clone: file listing, last commit, README and license, but no stars or
issue counts. Everything is
written in Common Lisp (SBCL) and runs with no server: the data lives in this
repository as one JSON file per day, and the site is deployed to GitHub Pages
from the same workflow run.

## How a day works

1. `make pool` shallow-clones `quicklisp/quicklisp-projects`.
2. `habichuela pick` derives a seed from the date, picks the source with a
   seeded roll, shuffles the candidates with the same seed, and takes the first
   one that passes the rules below. It writes `data/YYYY-MM-DD.json`. Running it
   twice on the same day is a no-op, and a rerun makes the same choices.
3. `habichuela refresh --limit 25` re-fetches stats for the 25 least recently
   refreshed records, so every record is refreshed roughly monthly.
4. The data is committed, then `habichuela build` writes `site/` and the
   workflow deploys it to GitHub Pages.

A candidate must be: not a fork or mirror, not archived, with a description and
a README, not featured before (the same owner/name on another forge counts as
featured), from an owner not featured in the last 30 days, and starred enough:
2 stars for Quicklisp projects on GitHub, none for Quicklisp projects elsewhere,
3 for GitHub search, 1 for GitLab and Codeberg search. Search picks must also
have Common Lisp as their primary language. When a search source yields nothing
eligible, the day falls back to the Quicklisp list.

How each forge is searched:

- GitHub: repository search, one random month of creation dates at a time,
  since search returns at most 1,000 results per query.
- GitLab: the `common-lisp` topic, then a name-and-description search for
  "lisp" in a random month of activity. GitLab's own language filter returns a
  server error for Common Lisp, so the primary language is checked per project.
- Codeberg: the `common-lisp` topic plus a name-and-description search, both
  filtered on the primary language the API reports.

The knobs are `defparameter`s at the top of `src/pick.lisp` and
`src/discover.lisp`: discovery share and forge odds, star minimums, owner
cooldown, attempt budget.

## Local use

Requirements: SBCL, git, curl, make. The GitHub token comes from `gh auth token`
when `GITHUB_TOKEN` is not set. `GITLAB_TOKEN` and `CODEBERG_TOKEN` are optional.

```sh
make deps                 # project-local Quicklisp pinned to quicklisp-dist.txt
make pool                 # fetch or update the Quicklisp projects list
make bin                  # build bin/habichuela
make pick ARGS=--dry-run  # show the pick for today without writing it
make pick                 # write data/YYYY-MM-DD.json
make refresh ARGS="--limit 5"
make build                # write site/
make serve                # preview at http://localhost:8000/
```

`HABICHUELA_DATE=2026-01-31 make pick` picks for another date.
`make pick ARGS="--dry-run --source codeberg"` forces a source
(`quicklisp`, `github`, `gitlab` or `codeberg`). `bin/habichuela pool` counts
the Quicklisp pool per forge. `bin/habichuela inspect <repo>` prints the record
that would be written for any repository, on any forge. `data/exclude.txt` lists repositories that must
never be featured, as `owner/name` or `host/owner/name`.

## Site

`static/` is copied into the site as is. `static/bean.png` is the logo,
favicon and link-preview image. The footer links the X, Mastodon and Bluesky
accounts with `rel="me"`, which is what Mastodon uses to verify a profile link.
Both lists live at the top of `src/site.lisp`.

## One-time GitHub setup

The site is served at https://habichue.la/.

1. Create the `habichuela` repository on GitHub and push this tree.
2. Settings, Pages, "Build and deployment", set Source to "GitHub Actions".
3. Under "Custom domain" on the same page, enter `habichue.la` and save.
   GitHub recommends verifying the domain for your account first (your
   profile settings, Pages, "Add a domain") to prevent takeovers.
4. At the registrar, point the apex at GitHub Pages and remove any URL
   forwarding record: A records 185.199.108.153, 185.199.109.153,
   185.199.110.153, 185.199.111.153, and AAAA records 2606:50c0:8000::153,
   2606:50c0:8001::153, 2606:50c0:8002::153, 2606:50c0:8003::153.
   Optionally add a `www` CNAME to `juliojimenez.github.io`.
5. Once GitHub has issued the certificate (up to a day), tick "Enforce HTTPS".
6. Actions, "daily", "Run workflow" to seed the first pick, or wait for the schedule.

The workflow reads the Pages configuration with `actions/configure-pages`, so
the absolute links in `feed.xml` follow whatever domain is set there. Local
builds default to `https://habichue.la/`; override with `HABICHUELA_BASE_URL`.

## Data

`data/YYYY-MM-DD.json` holds the pick and its latest stats snapshot:
repo, forge, host, url, description, homepage, language, license, stars, forks,
open_issues, created_at, pushed_at, archived, fork, mirror, default_branch,
topics, has_readme, has_tests, has_ci, asd_systems, tree_truncated,
quicklisp_project, source (`quicklisp`, `github`, `gitlab` or `codeberg`),
picked_at, fetched_at. The site publishes the same records as `data.json`, and
the 50 most recent picks as `feed.xml`. Feed entries have stable `tag:` ids and
carry the time the pick was made, so RSS-to-social services such as dlvr.it
see each pick exactly once.

`has_tests` is a heuristic: a `t/`, `test/` or `tests/` directory, or a file
named like `foo-test.asd`, `tests.lisp` or `run-tests.sh`. `has_ci` looks for
GitHub Actions, GitLab CI, Forgejo and Gitea Actions, Travis, CircleCI, Drone,
Woodpecker, Cirrus, sourcehut builds and a few others. `license` is the forge's
detected license when it names one. Otherwise the LICENSE or COPYING file is
fetched and identified from its wording (MIT, the BSD variants, Apache-2.0, the
GPL family including LLGPL, public-domain dedications, MPL-2.0, ISC, 0BSD,
Unlicense, Zlib, CC0-1.0 and a few more), and failing that the `:license`
string of the ASDF system definition is read. `license_from` says whether the
value came from the `forge`, the `file` or the `asd`. A license file nobody
could read reads "see repository".

## Known limitations

- Quicklisp projects on sourcehut, Bitbucket and other self-hosted git are
  skipped. Projects read from a clone (gitlab.common-lisp.net) have no stars,
  forks, issue counts or creation date; those fields are null and the site
  shows "n/a".
- Without a `GITLAB_TOKEN`, GitLab's API hides the archived flag, the mirror
  flag and the open issue count; those read as false and 0.
- Dependencies come from a Quicklisp dist pinned by date in
  `quicklisp-dist.txt`. The Quicklisp client itself downloads over plain HTTP
  and verifies archives against the dist index. Switching to ocicl or qlot is
  the upgrade path if that matters to you.
- GitHub's cron is best effort: the daily run can start late.
- HTTP requests go through curl, driven from Lisp, instead of a Lisp HTTP client.
  Every Lisp client depends on cl+ssl, which does not work with OpenSSL 4,
  Homebrew's default `openssl` since late 2026. The whole HTTP layer is one
  function in `src/http.lisp`, so swapping it back later is easy.

## License

Copyright 2026 Julio Jimenez. Licensed under the Apache License, Version 2.0;
see [LICENSE](LICENSE).
