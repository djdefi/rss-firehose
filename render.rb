#!/usr/bin/env ruby
# frozen_string_literal: true

require 'erb'
require 'rss'
require 'cgi'
require 'json'
require 'time'
require 'net/http'
require 'uri'
require 'fileutils'

# Per-feed HTTP timeout (seconds).
FETCH_TIMEOUT = 20
# Cap redirect hops so a misbehaving feed can't loop forever.
MAX_REDIRECTS = 5
# Bump when the cache entry shape changes so old caches are ignored.
CACHE_VERSION = 1
# Separate file for the AI summary cache.
AI_SUMMARY_CACHE_FILE = 'cache/ai_summary_cache.json'

FetchResult = Struct.new(:status, :body, :etag, :last_modified)
FeedOutcome = Struct.new(:feed, :url, :entry)

# ---------------------------------------------------------------------------
# Configuration helpers
# ---------------------------------------------------------------------------

def title
  t = ENV['RSS_TITLE'] || 'News Firehose'
  t.strip.empty? ? 'News Firehose' : t
end

def description
  d = ENV['RSS_DESCRIPTION'] || 'View the latest news.'
  d.strip.empty? ? 'View the latest news.' : d
end

def analytics_ua
  ENV['ANALYTICS_UA']
end

# Feed URLs come from RSS_URLS (comma-separated) or urls.txt. Blank lines and
# lines starting with '#' are ignored. URLs are validated for http(s) scheme.
def rss_urls
  raw = if ENV['RSS_URLS']
          ENV['RSS_URLS'].split(',')
        else
          File.readlines('urls.txt')
        end
  valid = raw.map(&:strip).reject { |u| u.empty? || u.start_with?('#') }
             .select { |u| u.match?(/\Ahttps?:\/\//) }
  puts "Warning: Some invalid URLs were filtered out" if valid.size < raw.reject(&:empty?).size
  valid.empty? ? rss_backup_urls : valid
rescue Errno::ENOENT
  puts "Warning: urls.txt not found, using backup URLs"
  rss_backup_urls
end

def rss_backup_urls
  urls = if ENV['RSS_BACKUP_URLS']
           ENV['RSS_BACKUP_URLS'].split(',').map(&:strip).reject(&:empty?)
         else
           ['https://calmatters.org/feed/']
         end
  urls.select { |u| u.match?(/\Ahttps?:\/\//) }
end

# How many feeds to fetch in parallel.
def fetch_concurrency
  [(ENV['RSS_CONCURRENCY'] || '8').to_i, 1].max
end

# ---------------------------------------------------------------------------
# Escaping / formatting helpers
# ---------------------------------------------------------------------------

# HTML-escape third-party feed content before it lands in the page.
def h(text)
  CGI.escapeHTML(text.to_s)
end

# Secure version of convert_markdown_links_to_html that prevents ReDoS attacks
def convert_markdown_links_to_html(text)
  text.gsub(/\[([^\]]{1,100})\]\(([^)\s]{1,200})\)/) do |match|
    link_text = h($1)
    url = $2
    if url.match?(/\A(https?|ftp):\/\//)
      "<a href=\"#{h(url)}\">#{link_text}</a>"
    else
      match
    end
  end
end

def format_ai_response(summary)
  summary = summary.gsub("\n", "<br/>")
  summary = summary.gsub(/(##\s*)(.*)/) { "<h2>#{h($2)}</h2>" }
  summary = convert_markdown_links_to_html(summary)
  summary = summary.gsub(/\*\*(.*?)\*\*/) { "<b>#{h($1)}</b>" }
  summary
end

def sanitize_response(response_body)
  JSON.parse(response_body)
rescue JSON::ParserError => e
  puts "JSON parsing error: #{e.message}"
  nil
end

# ---------------------------------------------------------------------------
# Feed URL/title normalization (RSS2 vs Atom)
# ---------------------------------------------------------------------------

# Link to a feed's site homepage (scheme + host).
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

# ---------------------------------------------------------------------------
# Low-level HTTP (stdlib Net::HTTP only, no gems)
# ---------------------------------------------------------------------------

# GET with conditional-request support. Returns a FetchResult; never raises.
def http_fetch(url, cached = nil, redirects_left = MAX_REDIRECTS)
  uri = URI.parse(url)
  response = Net::HTTP.start(uri.host, uri.port,
                             use_ssl: uri.scheme == 'https',
                             open_timeout: FETCH_TIMEOUT,
                             read_timeout: FETCH_TIMEOUT) do |http|
    request = Net::HTTP::Get.new(uri)
    request['User-Agent'] = 'rss-firehose'
    if cached
      request['If-None-Match']     = cached['etag']          if cached['etag']
      request['If-Modified-Since'] = cached['last_modified'] if cached['last_modified']
    end
    http.request(request)
  end

  case response
  when Net::HTTPNotModified
    FetchResult.new(:not_modified, nil, cached&.fetch('etag', nil), cached&.fetch('last_modified', nil))
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

# POST JSON (used for GitHub Models AI API). Returns raw response body or nil.
def http_post_json(url, headers, body_hash)
  uri = URI.parse(url)
  Net::HTTP.start(uri.host, uri.port,
                  use_ssl: uri.scheme == 'https',
                  open_timeout: 30,
                  read_timeout: 60) do |http|
    req = Net::HTTP::Post.new(uri)
    req['Content-Type'] = 'application/json'
    headers.each { |k, v| req[k] = v }
    req.body = body_hash.to_json
    http.request(req).body
  end
rescue StandardError => e
  puts "HTTP POST error to #{url}: #{e.message}"
  nil
end

# ---------------------------------------------------------------------------
# Feed fetching (concurrent, ETag-cached)
# ---------------------------------------------------------------------------

def build_entry(url, parsed, result)
  {
    'etag'          => result.etag,
    'last_modified' => result.last_modified,
    'site'          => site_url(url),
    'items'         => parsed.items.map { |i| { 'title' => item_title(i), 'link' => item_link(i) } },
    'fetched_at'    => Time.now.utc.iso8601
  }
end

def entry_to_feed(url, entry, error: nil)
  items = (entry['items'] || []).map { |i| { title: i['title'], link: i['link'] } }
  { url: url, site: entry['site'] || site_url(url), items: items, error: error }
end

def unavailable_feed(url)
  { url: url, site: site_url(url), items: [], error: 'unavailable' }
end

# Fetch and parse a single feed. Never raises. Resolution order:
#   304 Not Modified -> reuse cached copy
#   200 OK + parses  -> fresh copy
#   otherwise + cache -> serve last-known-good copy
#   otherwise        -> mark feed (unavailable)
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

# Fetch every feed concurrently, preserving urls.txt order.
def fetch_all(urls, cache)
  outcomes = Array.new(urls.size)
  queue = Queue.new
  urls.each_with_index { |url, index| queue << [index, url] }

  workers = urls.empty? ? 0 : [fetch_concurrency, urls.size].min
  threads = Array.new(workers) do
    Thread.new do
      loop do
        index, url = begin; queue.pop(true); rescue ThreadError; break; end
        outcomes[index] = fetch_feed(url, cache[url])
      end
    end
  end
  threads.each(&:join)
  outcomes
end

# ---------------------------------------------------------------------------
# Feed HTTP cache (ETag/Last-Modified, opt-in via RSS_CACHE env var)
# ---------------------------------------------------------------------------

def feed_cache_path
  path = ENV['RSS_CACHE']
  path && !path.empty? ? path : nil
end

def load_feed_cache
  path = feed_cache_path
  return {} unless path && File.exist?(path)

  data = JSON.parse(File.read(path))
  data['version'] == CACHE_VERSION ? (data['entries'] || {}) : {}
rescue StandardError => e
  warn "Cache load failed: #{e.class}: #{e.message}"
  {}
end

def save_feed_cache(entries)
  path = feed_cache_path
  return unless path

  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, JSON.generate('version' => CACHE_VERSION, 'entries' => entries))
rescue StandardError => e
  warn "Cache save failed: #{e.class}: #{e.message}"
end

# Fetch every feed exactly once (concurrently), refresh the cache, and memoize.
def feeds
  @feeds ||= begin
    cache = load_feed_cache
    outcomes = fetch_all(rss_urls, cache)
    save_feed_cache(outcomes.each_with_object({}) { |o, acc| acc[o.url] = o.entry if o.entry })
    outcomes.map(&:feed)
  end
end

# ---------------------------------------------------------------------------
# AI summarization (GitHub Models API, net/http, no httparty)
# ---------------------------------------------------------------------------

# Extract titles + links from a feed (accepts both Hash feeds and RSS objects).
def extract_feed_content(feed_data)
  return [] if feed_data.nil?

  items = if feed_data.is_a?(Hash)
            feed_data[:items] || []
          elsif feed_data.respond_to?(:items)
            feed_data.items.map { |i| { title: item_title(i), link: item_link(i) } }
          else
            []
          end
  items.map { |item|
    t = item.is_a?(Hash) ? item[:title] : item_title(item)
    l = item.is_a?(Hash) ? item[:link]  : item_link(item)
    "#{t} (#{l})"
  }.compact
rescue StandardError => e
  puts "Error extracting feed content: #{e.message}"
  []
end

# Call the GitHub Models chat completions endpoint. Returns formatted HTML or nil.
def call_ai(messages, temperature: 0.6, max_tokens: 300, top_p: 1)
  return nil unless ENV['GITHUB_TOKEN']

  body = http_post_json(
    "https://models.inference.ai.azure.com/chat/completions",
    { "Authorization" => "Bearer " + ENV.fetch('GITHUB_TOKEN') },
    {
      "messages"    => messages,
      "model"       => "gpt-4o-mini",
      "temperature" => temperature,
      "max_tokens"  => max_tokens,
      "top_p"       => top_p
    }
  )
  return nil unless body

  parsed = sanitize_response(body)
  return nil unless parsed && parsed["choices"] && !parsed["choices"].empty?

  format_ai_response(parsed["choices"].first["message"]["content"])
rescue StandardError => e
  puts "AI call error: #{e.message}"
  nil
end

def summarize_news(feed_data)
  return "No content available for summarization." if feed_data.nil?

  news_content = extract_feed_content(feed_data).join('. ')
  return "No articles available for summarization." if news_content.empty?

  unless ENV['GITHUB_TOKEN']
    puts "No GITHUB_TOKEN provided, skipping AI summarization"
    return "AI summarization unavailable - no API token configured."
  end

  result = call_ai(
    [
      { "role" => "system", "content" => "Summarize the key news stories and developments in under 150 words. Focus on the actual news events, facts, and analysis presented in the content. Write as if creating a front-page news digest. Use clear, journalistic language with varied sentence structure. Include specific names, places, dates, and substantive details when available. Avoid commenting on the news source itself." },
      { "role" => "user",   "content" => news_content[0..4096] }
    ],
    temperature: 0.6, max_tokens: 300
  )
  result || "Summary generation failed - no valid response from AI service."
rescue StandardError => e
  puts "Error summarizing news: #{e.message}"
  "Summary generation failed due to technical error."
end

def summarize_overall_news(feeds_data)
  return "No content available for summarization." if feeds_data.nil? || feeds_data.empty?

  all_content = feeds_data.flat_map { |f| extract_feed_content(f) }.join('. ')
  return "No articles available for summarization." if all_content.empty?

  unless ENV['GITHUB_TOKEN']
    puts "No GITHUB_TOKEN provided, skipping AI summarization"
    return "AI summarization unavailable - no API token configured."
  end

  result = call_ai(
    [
      { "role" => "system", "content" => "Create a front-page news summary under 200 words covering the major news stories and developments from all sources. Identify the most important stories, key themes, and significant trends. Write as a professional news editor would for a major newspaper's front page. Focus on what happened, who it affects, and why it matters. Use clear, authoritative journalistic language. Emphasize facts, context, and implications rather than just listing events. Avoid any commentary about news sources themselves." },
      { "role" => "user",   "content" => all_content[0..6144] }
    ],
    temperature: 0.4, max_tokens: 400, top_p: 0.95
  )
  result || "Summary generation failed - no valid response from AI service."
rescue StandardError => e
  puts "Error summarizing overall news: #{e.message}"
  "Summary generation failed due to technical error."
end

# ---------------------------------------------------------------------------
# YubaNet breaking news (net/http, no httparty)
# ---------------------------------------------------------------------------

def fetch_yubanet_breaking_news
  url = 'https://yubanet.com/featured/now/'
  result = http_fetch(url)
  return [] unless result.status == :ok && result.body

  entries = []
  result.body.scan(/<p><strong>([^<]{1,200}(?:AM|PM)[^<]{0,50})<\/strong>\s*([^<]{1,2000})<\/p>/m) do |timestamp, content|
    clean_content   = content.gsub(/<[^>]{1,50}>/, '').strip
    clean_timestamp = timestamp.strip
    next if clean_content.length < 10
    entries << { timestamp: clean_timestamp, content: clean_content, link: url }
  end

  puts "Fetched #{entries.size} breaking news entries from YubaNet"
  entries
rescue StandardError => e
  puts "Error fetching YubaNet breaking news: #{e.message}"
  []
end

def summarize_breaking_news(breaking_news)
  return "No breaking news available for summarization." if breaking_news.nil? || breaking_news.empty?

  content_text = breaking_news.first(5).map { |e| "#{e[:timestamp]}: #{e[:content]}" }.join('. ')
  return "No breaking news content available for summarization." if content_text.empty?

  unless ENV['GITHUB_TOKEN']
    puts "No GITHUB_TOKEN provided, skipping breaking news AI summarization"
    return "AI summarization unavailable - no API token configured."
  end

  result = call_ai(
    [
      { "role" => "system", "content" => "Create a concise summary of the breaking news updates under 100 words. Focus on the most critical information and current developments. Identify patterns, key issues, and immediate impacts. Use urgent but clear language appropriate for breaking news. Highlight what readers need to know right now." },
      { "role" => "user",   "content" => content_text[0..3072] }
    ],
    temperature: 0.3, max_tokens: 200, top_p: 0.9
  )
  result || "Summary generation failed - no valid response from AI service."
rescue StandardError => e
  puts "Error summarizing breaking news: #{e.message}"
  "Summary generation failed due to technical error."
end

# ---------------------------------------------------------------------------
# AI summary cache (separate from the feed ETag/HTTP cache)
# ---------------------------------------------------------------------------

def cache_ai_summary(summary)
  return unless summary && !summary.empty?

  FileUtils.mkdir_p('cache')
  File.open(AI_SUMMARY_CACHE_FILE, 'w') do |f|
    f.write({ timestamp: Time.now.utc.iso8601, summary: summary }.to_json)
  end
  puts "AI summary cached successfully"
rescue StandardError => e
  puts "Warning: Failed to cache AI summary: #{e.message}"
end

def load_cached_ai_summary
  if ENV['FORCE_REGENERATE'] == 'true'
    puts "Force regeneration enabled, skipping AI cache"
    return nil
  end
  return nil unless File.exist?(AI_SUMMARY_CACHE_FILE)

  data      = JSON.parse(File.read(AI_SUMMARY_CACHE_FILE))
  timestamp = Time.parse(data['timestamp'])
  summary   = data['summary']

  if Time.now.utc - timestamp < 6 * 60 * 60
    puts "Loaded cached AI summary from #{timestamp}"
    summary
  else
    puts "Cached AI summary expired, will generate new one"
    nil
  end
rescue JSON::ParserError, ArgumentError => e
  puts "Warning: Error loading cached AI summary: #{e.message}"
  nil
rescue StandardError => e
  puts "Warning: Unexpected error loading AI cache: #{e.message}"
  nil
end

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

def render_template(source, destination)
  template = ERB.new(File.read(source), trim_mode: '-')
  File.write(destination, template.result(binding))
end

def render
  FileUtils.mkdir_p('public')

  overall_summary       = nil
  feed_summaries        = {}
  breaking_news         = []
  breaking_news_summary = nil

  puts "RSS Firehose starting..."
  puts "Title: #{title}"
  puts "RSS URLs: #{rss_urls.join(', ')}"
  puts "GitHub Token: #{ENV['GITHUB_TOKEN'] ? 'configured' : 'not configured (AI summaries disabled)'}"

  if ENV['GITHUB_TOKEN']
    breaking_news         = fetch_yubanet_breaking_news
    breaking_news_summary = summarize_breaking_news(breaking_news)

    cached_summary = load_cached_ai_summary
    if cached_summary
      overall_summary = cached_summary
      feed_summaries  = feeds.each_with_object({}) { |f, h| h[f[:url]] = "Cached summary used." }
      puts "Using cached AI summary."
    else
      puts "Generating AI summaries for #{feeds.size} feeds..."
      feed_summaries  = feeds.each_with_object({}) { |f, h| h[f[:url]] = summarize_news(f) }
      overall_summary = summarize_overall_news(feeds)
      if overall_summary && !overall_summary.include?("unavailable") && !overall_summary.include?("failed")
        cache_ai_summary(overall_summary)
        puts "Generated and cached new AI summary."
      else
        puts "Generated AI summary but not caching due to errors."
      end
    end
    puts "Overall Summary: #{overall_summary}"
  end

  render_template('templates/manifest.json.erb', 'public/manifest.json') if File.exist?('templates/manifest.json.erb')
  render_template('templates/index.html.erb',    'public/index.html')
  puts "Successfully rendered HTML."
rescue StandardError => e
  puts "Error during rendering: #{e.message}"
  puts e.backtrace.first(5).join("\n")
end

render if __FILE__ == $PROGRAM_NAME
