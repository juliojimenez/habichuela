# habichuela

A Common Lisp repository a day. Every day a GitHub Actions job picks one
Common Lisp repository, records its stats (stars, last update, license,
whether it has tests and CI, ASDF systems), and rebuilds a static site with
the archive of every pick plus an Atom feed.

Picks come from two sources, chosen per day:

- **Quicklisp**, about half the days: the Quicklisp projects list, a curated
  set of roughly 2,000 libraries. Only the GitHub-hosted ones are candidates.
- **GitHub search**, the other half: repositories whose primary language is
  Common Lisp and that are *not* in Quicklisp. Search returns at most 1,000
  results per query, so the job searches one random month of creation dates
  at a time, and every month since 2008 has the same odds.

Everything is written in Common Lisp (SBCL) and runs with no server: the data
lives in this repository as one JSON file per day, and the site is deployed
to GitHub Pages from the same workflow run.

## How a day works

1. `make pool` shallow-clones `quicklisp/quicklisp-projects`.
2. `habichuela pick` derives a seed from the date, flips a seeded coin to
   choose the source, shuffles the candidates with the same seed, and takes
   the first one that passes the rules below. It writes `data/YYYY-MM-DD.json`.
   Running it twice on the same day is a no-op, and a rerun makes the same
   choices.
3. `habichuela refresh --limit 25` re-fetches stats for the 25 least recently
   refreshed records, so every record is refreshed roughly monthly.
4. The data is committed, then `habichuela build` writes `site/` and the
   workflow deploys it to GitHub Pages.

A candidate must be: not a fork, not archived, with a description and a
README, not featured before, from an owner not featured in the last 30 days,
and with at least 2 stars from Quicklisp or 3 stars from GitHub search (there
is no curation there, so the bar is a little higher). If eight searched months
yield nothing eligible, the day falls back to the Quicklisp list.

The knobs are `defparameter`s at the top of `src/pick.lisp` and
`src/discover.lisp`: share of search days, star minimums, owner cooldown,
attempt budget.

## Local use

Requirements: SBCL, git, curl, make. The GitHub token comes from `gh auth token`
when `GITHUB_TOKEN` is not set.

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
`make pick ARGS="--dry-run --source github"` forces a source.
`data/exclude.txt` lists repositories that must never be featured.

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
repo, url, description, homepage, language, license, stars, forks,
open_issues, created_at, pushed_at, archived, fork, default_branch, topics,
has_readme, has_tests, has_ci, asd_systems, tree_truncated,
quicklisp_project, source (`quicklisp` or `github`), fetched_at. The site
publishes the same records as `data.json`, and the 50 most recent picks as
`feed.xml`.

`has_tests` is a heuristic: a `t/`, `test/` or `tests/` directory, or a file
named like `foo-test.asd`, `tests.lisp` or `run-tests.sh`. `has_ci` looks for
GitHub Actions, GitLab CI, Travis, CircleCI, Drone, Woodpecker, Cirrus,
sourcehut builds and a few others.

## Known limitations

- Quicklisp projects hosted elsewhere (GitLab, Codeberg, sourcehut, self-hosted
  git) are skipped, and GitHub search only sees repositories whose primary
  language GitHub detects as Common Lisp.
- Dependencies come from a Quicklisp dist pinned by date in
  `quicklisp-dist.txt`. The Quicklisp client itself downloads over plain HTTP
  and verifies archives against the dist index. Switching to ocicl or qlot is
  the upgrade path if that matters to you.
- GitHub's cron is best effort: the daily run can start late.
- HTTP requests go through curl, driven from Lisp, instead of a Lisp HTTP client.
  Every Lisp client depends on cl+ssl, which does not work with OpenSSL 4,
  Homebrew's default `openssl` since late 2026. The whole HTTP layer is one
  function in `src/github.lisp`, so swapping it back later is easy.
