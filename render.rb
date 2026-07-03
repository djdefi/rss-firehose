#!/usr/bin/env ruby
require 'erb'
require 'rss'
require 'cgi'
require 'net/http'
require 'uri'

# Per-feed HTTP timeout (seconds). Kept short so a single slow feed can't stall
# the whole render on low-bandwidth connections.
FETCH_TIMEOUT = 20

# Cap redirect hops so a misbehaving feed can't loop forever.
MAX_REDIRECTS = 5

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

# Fetch a URL, following redirects, returning the response body or nil on any
# error. Uses only the standard library so the renderer stays dependency-free.
def http_get(url, redirects_left = MAX_REDIRECTS)
  uri = URI.parse(url)
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                                 open_timeout: FETCH_TIMEOUT,
                                                 read_timeout: FETCH_TIMEOUT) do |http|
    request = Net::HTTP::Get.new(uri)
    request['User-Agent'] = 'rss-firehose'
    http.request(request)
  end

  case response
  when Net::HTTPSuccess
    response.body
  when Net::HTTPRedirection
    raise "too many redirects for #{url}" if redirects_left <= 0

    http_get(URI.join(url, response['location']).to_s, redirects_left - 1)
  else
    warn "Failed to fetch #{url}: HTTP #{response.code}"
    nil
  end
rescue StandardError => e
  warn "Failed to fetch #{url}: #{e.class}: #{e.message}"
  nil
end

# Fetch and parse a single feed into a normalized hash. Never raises: an
# unreachable or malformed feed yields an entry with :error set and no items,
# so one bad feed can't break the whole page. We don't validate because some
# feeds are slightly malformed and would otherwise fail to parse at all.
def fetch_feed(url)
  body = http_get(url)
  parsed = body && RSS::Parser.parse(body, false)
  items = parsed ? parsed.items.map { |i| { title: item_title(i), link: item_link(i) } } : []
  { url: url, site: site_url(url), items: items, error: parsed ? nil : 'unavailable' }
rescue StandardError => e
  warn "Failed to parse #{url}: #{e.class}: #{e.message}"
  { url: url, site: site_url(url), items: [], error: 'unavailable' }
end

# Fetch every feed exactly once. Memoized so the template can reference the data
# repeatedly without triggering extra HTTP requests (bandwidth stays minimal).
def feeds
  @feeds ||= rss_urls.map { |url| fetch_feed(url) }
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
