## rss-firehose

Aggregate Local RSS feeds into a lightweight page.

Example page: https://djdefi.github.io/rss-firehose/

### Rendering:

To render the page:

```
ruby render.rb
```

Outputs to: `public/index.html` (and `public/manifest.json`).

`render.rb` uses only the Ruby standard library (Ruby 2.6+), so there are no gems
to install. Feeds that are unreachable or malformed are skipped and marked
`(unavailable)` rather than breaking the whole page. Feeds are fetched
concurrently, so the render takes about as long as the single slowest feed
instead of the sum of them all.

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

The Docker image runs on Ruby 4.0. YJIT is intentionally left off: JIT warmup
never pays off for a short-lived one-shot, so the wins come from concurrency and
caching, not the interpreter.

### Tests

```
ruby -Itest test/render_test.rb
```

### Docker

Served up on port 8080 with nginx:

```
docker build -t djdefi/rss-firehose .
docker run --rm -v rss-firehose:/usr/src/app/public -it djdefi/rss-firehose
docker run --name rss-nginx --rm -v rss-firehose:/usr/share/nginx/html:ro -p 8080:80 nginx:alpine
```

Re-run the `rss-firehose` container to update the page.

#### Environment variables

Optional settings can be configured an Docker run time, or be set in your local Ruby environment:

```

## Docker:

docker run --rm -v rss-firehose:/usr/src/app/public -e "RSS_TITLE=My News" -e "RSS_URLS=https://url1/feed,http://url2/rss" -e "ANALYTICS_UA=UA-XXXXX-Y" -it djdefi/rss-firehose

## Ruby:

export RSS_URLS="https://url1/feed,http://url2/rss"
ruby render.rb

```

Available environment variable options:

```
"ANALYTICS_UA=UA-XXXXX-Y"
"RSS_URLS=https://url1/feed,http://url2/rss"
"RSS_TITLE=My News"
"RSS_DESCRIPTION=My really awesome news aggregation page"
"RSS_CONCURRENCY=8"
"RSS_CACHE=.cache/http_cache.json"
```
