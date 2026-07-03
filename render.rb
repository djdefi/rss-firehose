#!/usr/bin/env ruby
require 'erb'
require 'rss'
require 'cgi'
require 'json'
require 'time'
require 'net/http'
require 'uri'

# Per-feed HTTP timeout (seconds). Kept short so a single slow feed can't stall
# the whole render on low-bandwidth connections.
FETCH_TIMEOUT = 20

# Cap redirect hops so a misbehaving feed can't loop forever.
MAX_REDIRECTS = 5

# Bump when the cache entry shape changes so old caches are ignored.
CACHE_VERSION = 1

FetchResult = Struct.new(:status, :body, :etag, :last_modified)
FeedOutcome = Struct.new(:feed, :url, :entry)

def title
  ENV['RSS_TITLE'] || 'News Firehose'
end

def description
  ENV['RSS_DESCRIPTION'] || 'View the latest news.'
end

def analytics_ua
  ENV['ANALYTICS_UA']
end

# Feed URLs come from RSS_URLS (comma separated) or urls.txt. Blank lines and
# '#' comments are ignored so the file is easy to hand-edit.
def rss_urls
  raw = ENV['RSS_URLS'] ? ENV['RSS_URLS'].split(',') : File.readlines('urls.txt')
  raw.map(&:strip).reject { |u| u.empty? || u.start_with?('#') }
end

# How many feeds to fetch in parallel. Feeds are network-bound, so fetching them
# concurrently turns N sequential round-trips into roughly one.
def fetch_concurrency
  [(ENV['RSS_CONCURRENCY'] || '8').to_i, 1].max
end

# HTML-escape third-party feed content before it lands in the page. Feeds are
# untrusted input, so this guards against markup/script injection.
def h(text)
  CGI.escapeHTML(text.to_s)
end

# Link to a feed's site homepage (scheme + host). Robust across the many feed
# URL shapes we aggregate (/feed/, .aspx, search?f=rss, ...).
def site_url(url)
  uri = URI.parse(url)
  uri.scheme && uri.host ? "#{uri.scheme}://#{uri.host}" : url
rescue URI::InvalidURIError
  url
end

# Normalize an item title across RSS (String) and Atom (object with #content).
def item_title(item)
  raw = item.title
  raw.respond_to?(:content) ? raw.content.to_s : raw.to_s
end

# Normalize an item link across RSS (String) and Atom (object with #href).
def item_link(item)
  raw = item.link
  return raw.href.to_s if raw.respond_to?(:href)
  return raw.content.to_s if raw.respond_to?(:content)

  raw.to_s
end

# Fetch a URL, following redirects and honoring the cached validators for a
# conditional request. Returns a FetchResult; never raises. A 304 Not Modified
# means the caller should reuse its cached copy (no body was transferred).
def http_fetch(url, cached = nil, redirects_left = MAX_REDIRECTS)
  uri = URI.parse(url)
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                                 open_timeout: FETCH_TIMEOUT,
                                                 read_timeout: FETCH_TIMEOUT) do |http|
    request = Net::HTTP::Get.new(uri)
    request['User-Agent'] = 'rss-firehose'
    if cached
      request['If-None-Match'] = cached['etag'] if cached['etag']
      request['If-Modified-Since'] = cached['last_modified'] if cached['last_modified']
    end
    http.request(request)
  end

  case response
  when Net::HTTPNotModified
    FetchResult.new(:not_modified, nil, cached && cached['etag'], cached && cached['last_modified'])
  when Net::HTTPSuccess
    FetchResult.new(:ok, response.body, response['etag'], response['last-modified'])
  when Net::HTTPRedirection
    raise "too many redirects for #{url}" if redirects_left <= 0

    http_fetch(URI.join(url, response['location']).to_s, cached, redirects_left - 1)
  else
    warn "Failed to fetch #{url}: HTTP #{response.code}"
    FetchResult.new(:error, nil, nil, nil)
  end
rescue StandardError => e
  warn "Failed to fetch #{url}: #{e.class}: #{e.message}"
  FetchResult.new(:error, nil, nil, nil)
end

# Build a JSON-serializable cache entry (string keys) from a parsed feed.
def build_entry(url, parsed, result)
  {
    'etag' => result.etag,
    'last_modified' => result.last_modified,
    'site' => site_url(url),
    'items' => parsed.items.map { |i| { 'title' => item_title(i), 'link' => item_link(i) } },
    'fetched_at' => Time.now.utc.iso8601
  }
end

# Convert a cache entry into the symbol-keyed hash the template renders.
def entry_to_feed(url, entry, error: nil)
  items = (entry['items'] || []).map { |i| { title: i['title'], link: i['link'] } }
  { url: url, site: entry['site'] || site_url(url), items: items, error: error }
end

def unavailable_feed(url)
  { url: url, site: site_url(url), items: [], error: 'unavailable' }
end

# Fetch and parse a single feed into a FeedOutcome (the rendered feed plus the
# cache entry to persist). Never raises. Resolution order:
#   304 Not Modified -> reuse cached copy (cheap, no body transferred)
#   200 OK + parses  -> fresh copy, refresh the cache
#   otherwise + cache-> serve the last-known-good copy (stay up when a feed dies)
#   otherwise        -> mark the feed (unavailable)
# We don't validate the feed because some are slightly malformed and would
# otherwise fail to parse at all.
def fetch_feed(url, cached)
  result = http_fetch(url, cached)

  if result.status == :not_modified && cached
    return FeedOutcome.new(entry_to_feed(url, cached), url, cached)
  end

  if result.status == :ok && (parsed = RSS::Parser.parse(result.body, false))
    entry = build_entry(url, parsed, result)
    return FeedOutcome.new(entry_to_feed(url, entry), url, entry)
  end

  if cached
    warn "Serving cached copy for #{url} (#{result.status})"
    return FeedOutcome.new(entry_to_feed(url, cached), url, cached)
  end

  FeedOutcome.new(unavailable_feed(url), url, nil)
rescue StandardError => e
  warn "Failed to build feed for #{url}: #{e.class}: #{e.message}"
  cached ? FeedOutcome.new(entry_to_feed(url, cached), url, cached) : FeedOutcome.new(unavailable_feed(url), url, nil)
end

# Fetch every feed concurrently, preserving urls.txt order. Worker threads only
# read the shared cache; the updated cache is assembled after they join, so no
# locking is needed.
def fetch_all(urls, cache)
  outcomes = Array.new(urls.size)
  queue = Queue.new
  urls.each_with_index { |url, index| queue << [index, url] }

  workers = urls.empty? ? 0 : [fetch_concurrency, urls.size].min
  threads = Array.new(workers) do
    Thread.new do
      loop do
        index, url = begin
          queue.pop(true)
        rescue ThreadError
          break
        end
        outcomes[index] = fetch_feed(url, cache[url])
      end
    end
  end
  threads.each(&:join)
  outcomes
end

# Optional on-disk HTTP cache (set RSS_CACHE to a file path to enable). Persisting
# it between runs lets conditional requests return 304s, sparing upstream feeds.
def cache_path
  path = ENV['RSS_CACHE']
  path && !path.empty? ? path : nil
end

def load_cache
  path = cache_path
  return {} unless path && File.exist?(path)

  data = JSON.parse(File.read(path))
  data['version'] == CACHE_VERSION ? (data['entries'] || {}) : {}
rescue StandardError => e
  warn "Cache load failed: #{e.class}: #{e.message}"
  {}
end

def save_cache(entries)
  path = cache_path
  return unless path

  require 'fileutils'
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, JSON.generate('version' => CACHE_VERSION, 'entries' => entries))
rescue StandardError => e
  warn "Cache save failed: #{e.class}: #{e.message}"
end

# Fetch every feed exactly once (concurrently), refresh the cache, and memoize so
# the template can reference the data repeatedly without extra HTTP requests.
def feeds
  @feeds ||= begin
    cache = load_cache
    outcomes = fetch_all(rss_urls, cache)
    save_cache(outcomes.each_with_object({}) { |o, acc| acc[o.url] = o.entry if o.entry })
    outcomes.map(&:feed)
  end
end

def render_template(source, destination)
  template = ERB.new(File.read(source), trim_mode: '-')
  File.write(destination, template.result(binding))
end

def render
  render_template('templates/manifest.json.erb', 'public/manifest.json')
  render_template('templates/index.html.erb', 'public/index.html')
end

render if __FILE__ == $PROGRAM_NAME
