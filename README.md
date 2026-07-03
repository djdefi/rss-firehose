## rss-firehose

Aggregate Local RSS feeds into a lightweight page.

Example page: https://djdefi.github.io/rss-firehose/

### Rendering

To render the page:

```
ruby render.rb
```

Outputs to: `public/index.html` (and `public/manifest.json`).

`render.rb` uses only the Ruby standard library (Ruby 2.6+), so there are no gems
to install. Feeds that are unreachable or malformed are skipped and marked
`(unavailable)` rather than breaking the whole page.

Feed URLs are read from `urls.txt` (one per line; blank lines and lines starting
with `#` are ignored) or from the `RSS_URLS` environment variable.

### Performance & caching

The renderer is a one-shot: it fetches every feed, writes the static page, and
exits. Two things keep that one-shot fast and gentle on upstream servers:

- **Concurrent fetching** — feeds are downloaded in parallel (default 8 at a
  time, tune with `RSS_CONCURRENCY`). Wall-clock time is bound by the slowest
  feed rather than the total.
- **Conditional-GET caching** — set `RSS_CACHE` to a file path to persist an
  HTTP cache. Subsequent runs send `If-None-Match` / `If-Modified-Since`, so
  unchanged feeds return a cheap `304 Not Modified` (no body transferred, no
  re-parse). If a feed is temporarily down, the last-known-good copy is served
  instead of dropping it. Caching is off unless `RSS_CACHE` is set. In CI the
  cache file is persisted between scheduled runs via `actions/cache`.

### Tests

```
ruby -Itest test/render_test.rb
```

### Docker

Build and run:

```
docker build -t djdefi/rss-firehose .
docker run --rm -v rss-firehose:/usr/src/app/public -it djdefi/rss-firehose
docker run --name rss-nginx --rm -v rss-firehose:/usr/share/nginx/html:ro -p 8080:80 nginx:alpine
```

Re-run the `rss-firehose` container to update the page.

### Environment variables

Optional settings can be configured at Docker run time, or be set in your local Ruby environment:

```bash
ANALYTICS_UA=UA-XXXXX-Y
RSS_URLS=https://url1/feed,http://url2/rss
RSS_BACKUP_URLS=https://backup1/feed,http://backup2/rss
RSS_TITLE=My News
RSS_DESCRIPTION=My really awesome news aggregation page
RSS_CONCURRENCY=8           # parallel feed fetches (default 8)
RSS_CACHE=.cache/http.json  # path for ETag/HTTP cache (optional)
GITHUB_TOKEN=your_github_token_for_ai_summaries
FORCE_REGENERATE=true       # skip AI summary cache and force full regeneration
```

### AI-Powered Summaries

RSS Firehose can generate AI-powered summaries of your news feeds using GitHub's Models service. To enable:

1. Set the `GITHUB_TOKEN` environment variable with your GitHub personal access token
2. Summaries are cached for 6 hours to minimize API usage
3. If no token is provided, the app gracefully falls back to displaying feeds without summaries

#### Forcing Full Regeneration

To skip the AI summary cache and force a fresh summary:

**GitHub Actions Workflow Dispatch:**
1. Go to the Actions tab → "Auto pages deploy" workflow → "Run workflow"
2. Select `true` for "Force full regeneration (skip AI summary cache)"

**Local:**
```bash
FORCE_REGENERATE=true ruby render.rb
```

### Features

- **Pure stdlib** — zero runtime gems; `render.rb` runs on any Ruby 2.6+
- **Concurrent fetching** — parallel feeds, wall-clock bound by slowest feed
- **Conditional-GET caching** — ETag/304 support reduces bandwidth and upstream load
- **Robust error handling** — bad/offline feeds render `(unavailable)`, never crash the page
- **XSS protection** — all feed content is HTML-escaped before rendering
- **Atom + RSS2 support** — title/link normalized across both feed types
- **AI summarization** — optional AI-powered news summaries via GitHub Models
- **Smart backup feeds** — fallback URLs when primary feeds are empty
- **Responsive design** — mobile-friendly HTML with accessibility features
