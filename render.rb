#!/usr/bin/env ruby
# frozen_string_literal: true

require 'erb'
require 'rss'
require 'httparty'
require 'json'
require 'time'
require 'fileutils'
require 'cgi'
require 'digest'

CACHE_FILE = 'cache/ai_summary_cache.json'

# Directory of last-good raw feed bodies. Many regional news sites sit behind a
# WAF that intermittently throttles GitHub's datacenter IPs (observed: HTTP
# 202/403/429 with an empty body minutes after a clean 200). When a live fetch
# is throttled, we fall back to the most recent successfully-fetched copy so
# readers see real content instead of an offline placeholder. Lives under the
# gitignored cache/ dir, which the workflow already persists across runs via
# actions/cache, so no workflow change is needed.
FEED_CACHE_DIR = 'cache/feeds'

# Fallback sources for a primary feed that is throttled/blocked from GitHub's
# datacenter IPs. Some regional papers (e.g. The Union) return HTTP 429/403 to
# the runner even though they work from residential IPs; when the primary has
# no live response and no cache, we pull the same beat from a runner-reachable
# alternate before showing an offline placeholder. Keyed by primary URL; the
# rendered card then naturally shows the alternate's own name/links.
FEED_FALLBACKS = {
  'https://www.theunion.com/search/?f=rss&t=article&c=news' => [
    'https://sierranevadaally.org/feed/'
  ]
}.freeze

# Channel title stamped on the placeholder feed built for an offline/failed
# source (see create_offline_feed). Callers use feed_offline? to detect it.
FEED_OFFLINE_TITLE = 'Feed currently offline'

# Seconds to wait before the single feed re-fetch. A brief pause lets a
# transient upstream hiccup (rate-limit/blip from the CI runner IP) recover
# instead of flipping the feed to the offline placeholder. Override/disable
# with FEED_RETRY_DELAY (e.g. 0 in tests).
FEED_RETRY_DELAY = (ENV['FEED_RETRY_DELAY'] || '2').to_f

# Canned summarizer outputs that mean "no real content was produced". These
# must never be cached, or a degraded (e.g. all-feeds-offline) render would
# freeze for the whole cache TTL on rapid reruns.
PLACEHOLDER_SUMMARIES = [
  'No content available for summarization.',
  'No articles available for summarization.'
].freeze

# Maximum length of a friendly feed name before it is truncated with an
# ellipsis (see feed_display_name), so a long channel title can't dominate the
# layout or reintroduce horizontal overflow on narrow screens.
FEED_NAME_MAX = 40

# Maximum length of a single item's description fed to the summarizer (see
# item_description). Caps how much one verbose article can consume of the
# token-bounded content window, so several items still fit and the AI gets
# breadth as well as depth.
ITEM_DESC_MAX = 240

# National Weather Service active-alerts API + the zone to watch. CAC057 is
# Nevada County, CA (covers Nevada City, Grass Valley and Truckee); override
# with NWS_ALERT_ZONE (any NWS county "CACnnn" or forecast/fire "CAZnnn" UGC).
# The band is the "high-signal, only-when-active" critical strip: it renders
# nothing when there are no qualifying alerts. NWS requires a descriptive
# User-Agent or it returns 403.
NWS_ALERTS_ENDPOINT = 'https://api.weather.gov/alerts/active'
NWS_ALERT_ZONE = (ENV['NWS_ALERT_ZONE'] || 'CAC057').strip
NWS_USER_AGENT = 'rss-firehose (https://github.com/djdefi/rss-firehose)'

# Only genuinely critical, actionable alerts belong in the band. Keep an alert
# if its severity is Severe/Extreme (NWS "Warnings") or its event matches one
# of these life-safety types, so routine advisories (Lake Wind, Heat Advisory)
# are filtered out.
NWS_CRITICAL_EVENTS = /red flag|fire warning|fire weather|evacuation|flood|tornado|tsunami|hurricane|extreme|blizzard|severe thunderstorm/i
NWS_CRITICAL_SEVERITIES = %w[Severe Extreme].freeze
# Cap how many alerts the band lists, newest first, so a busy alert day can't
# push the actual news far down the page.
NWS_ALERT_MAX = 6

def title
  title = ENV['RSS_TITLE'] || 'News Firehose'
  title.strip.empty? ? 'News Firehose' : title
end

def rss_urls
  urls = if ENV['RSS_URLS']
           ENV['RSS_URLS'].split(',').map(&:strip).reject(&:empty?)
         else
           begin
             File.readlines('urls.txt').map(&:chomp).reject(&:empty?)
           rescue Errno::ENOENT
             puts "Warning: urls.txt not found, using backup URLs"
             []
           end
         end
  
  # Validate URLs
  valid_urls = urls.select do |url|
    url.match?(/\Ahttps?:\/\//)
  end
  
  if valid_urls != urls
    puts "Warning: Some invalid URLs were filtered out"
  end
  
  valid_urls.empty? ? rss_backup_urls : valid_urls
end

def rss_backup_urls
  urls = if ENV['RSS_BACKUP_URLS']
           ENV['RSS_BACKUP_URLS'].split(',').map(&:strip).reject(&:empty?)
         else
           ['https://calmatters.org/feed/']
         end
  
  # Validate backup URLs
  urls.select { |url| url.match?(/\Ahttps?:\/\//) }
end

def description
  desc = ENV['RSS_DESCRIPTION'] || 'View the latest news.'
  desc.strip.empty? ? 'View the latest news.' : desc
end

def analytics_ua
  ENV['ANALYTICS_UA']
end

def render_html(feeds, overall_summary, feed_summaries, breaking_news = [], breaking_news_summary = nil, weather_alerts = [])
  begin
    html = File.open('templates/index.html.erb').read
    template = ERB.new(html, trim_mode: '-')
    File.open('public/index.html', 'w') do |f|
      f.puts template.result(binding)
    end
  rescue => e
    puts "Warning: Failed to render HTML. Error: #{e.message}"
  end
end

def render_manifest
  begin
    json = File.open('templates/manifest.json.erb').read
    template = ERB.new(json, trim_mode: '-')
    File.open('public/manifest.json', 'w') do |f|
      f.puts template.result(binding)
    end
  rescue => e
    puts "Warning: Failed to manifest JSON. Error: #{e.message}"
  end
end

# Fetch a feed URL and parse it, returning the RSS object or nil on ANY
# failure — non-200, network error (timeout/reset/DNS), or parse error. Kept
# separate from feed() so a transient failure of either kind can be retried by
# simply calling it again.
def fetch_and_parse_feed(url)
  response = HTTParty.get(url, timeout: 60, headers: { 'User-Agent' => 'rss-firehose feed aggregator' })
  return nil unless response.code == 200

  parsed = RSS::Parser.parse(response.body, false)
  # Only cache a body we know is good (parsed and non-empty) so a throttled
  # response that happens to arrive as HTTP 200 can't overwrite the last-good copy.
  save_cached_feed(url, response.body) if parsed && !parsed.items.empty?
  parsed
rescue HTTParty::Error, RSS::Error => e
  puts "Error fetching or parsing feed from '#{url}': #{e.class} - #{e.message}"
  nil
rescue => e
  puts "General error with feed '#{url}': #{e.message}"
  nil
end

# Filesystem path of the last-good cached body for a feed URL. The URL is
# hashed so the filename is always filesystem-safe regardless of query strings.
def feed_cache_path(url)
  File.join(FEED_CACHE_DIR, "#{Digest::SHA1.hexdigest(url.to_s)}.xml")
end

# Persist a known-good raw feed body for later reuse. Fails soft: a cache write
# problem must never break rendering.
def save_cached_feed(url, body)
  return if body.nil? || body.to_s.empty?

  FileUtils.mkdir_p(FEED_CACHE_DIR)
  File.write(feed_cache_path(url), body)
rescue StandardError => e
  puts "Could not cache feed '#{url}': #{e.message}"
end

# Load and parse the last-good cached body for a feed, or nil when there is no
# usable cache (missing file, unparseable, or empty).
def load_cached_feed(url)
  path = feed_cache_path(url)
  return nil unless File.exist?(path)

  parsed = RSS::Parser.parse(File.read(path), false)
  parsed if parsed && !parsed.items.empty?
rescue StandardError
  nil
end

# Get the feeds and parse them. We don't validate because some feeds are
# malformed slightly and break the parser. A single retry (after a brief
# FEED_RETRY_DELAY) covers a transient upstream failure of any kind — a
# timeout/reset, a non-200, or an empty/partial response. When the primary is
# still down we degrade gracefully through: live fallback source → primary's
# last-good cache → fallback's cache → offline placeholder.
def feed(url, fallbacks = FEED_FALLBACKS.fetch(url, []))
  rss_content = fetch_and_parse_feed(url)

  if rss_content.nil? || rss_content.items.empty?
    puts "Feed from '#{url}' returned no items, retrying once..."
    sleep(FEED_RETRY_DELAY) if FEED_RETRY_DELAY.positive?
    rss_content = fetch_and_parse_feed(url)
  end
  return rss_content if rss_content && !rss_content.items.empty?

  # Primary is down. Priority: a FRESH alternate source beats a STALE cache, so
  # the beat stays current — try live fallbacks, then the primary's last-good
  # cache, then the fallbacks' caches, and only then an offline placeholder.
  fallbacks.each do |fb_url|
    fb = fetch_and_parse_feed(fb_url)
    next unless fb && !fb.items.empty?

    puts "Feed '#{url}' unavailable; using live fallback source '#{fb_url}'."
    return fb
  end

  cached = load_cached_feed(url)
  if cached
    puts "Feed from '#{url}' failed after retry; serving last-good cached copy."
    return cached
  end

  fallbacks.each do |fb_url|
    fb_cached = load_cached_feed(fb_url)
    next unless fb_cached

    puts "Feed '#{url}' unavailable; serving cached fallback '#{fb_url}'."
    return fb_cached
  end

  puts "Feed from '#{url}' failed after retry; using offline placeholder."
  create_offline_feed(url)
end

# Create a placeholder RSS feed object for offline/failed feeds
def create_offline_feed(url)
  rss_content = RSS::Rss.new('2.0')
  rss_content.channel = RSS::Rss::Channel.new
  rss_content.channel.title = FEED_OFFLINE_TITLE
  rss_content.channel.link = url
  rss_content.channel.description = "The feed from '#{url}' is currently offline or returned no items."
  
  # Add a placeholder item
  item = RSS::Rss::Channel::Item.new
  item.title = "Feed offline: #{url}"
  item.link = url
  item.description = "This feed is currently unavailable."
  rss_content.channel.items << item
  
  rss_content
end

# True when the feed is the offline placeholder built by create_offline_feed.
# Its only "item" is the bare feed URL, which is useless (and actively harmful)
# to summarize: the AI model responds with a refusal like "I'm unable to access
# external websites", which then leaks to visitors. Summary callers skip these.
def feed_offline?(feed)
  feed.respond_to?(:channel) &&
    feed.channel.respond_to?(:title) &&
    feed.channel.title == FEED_OFFLINE_TITLE
rescue StandardError
  false
end

# Apply the block to each item across a bounded thread pool, returning an
# (unordered) Hash of { item => block_result }. Used to pipeline the one-shot's
# independent network I/O — feed fetches and the per-feed/overall/breaking AI
# summary calls — so wall-clock is roughly the slowest single call instead of
# the sum of them all. Concurrency is bounded (default 8, override with
# FEED_CONCURRENCY).
def parallel_map(items)
  results = {}
  return results if items.empty?

  max_threads = (ENV['FEED_CONCURRENCY'] || '8').to_i
  max_threads = 1 if max_threads < 1
  worker_count = [max_threads, items.size].min

  queue = Queue.new
  items.each { |item| queue << item }
  mutex = Mutex.new

  workers = Array.new(worker_count) do
    Thread.new do
      loop do
        item = begin
          queue.pop(true)
        rescue ThreadError
          break
        end
        value = yield(item)
        mutex.synchronize { results[item] = value }
      end
    end
  end
  workers.each(&:join)
  results
end

# Fetch and parse all feeds concurrently. Feeds are independent network I/O, so
# parallelizing collapses the one-shot's fetch time from the sum of every
# request to roughly the slowest single feed. Input URL order is preserved and
# each feed still flows through feed(), so the retry/offline-placeholder
# behavior is unchanged — only wall-clock time drops.
def fetch_feeds(urls)
  return {} if urls.empty?

  results = parallel_map(urls) do |url|
    begin
      feed(url)
    rescue StandardError => e
      puts "Unexpected error fetching '#{url}': #{e.message}"
      create_offline_feed(url)
    end
  end

  # Preserve input order and drop nils, matching the previous
  # `rss_urls.map { ... }.to_h.compact` behavior.
  urls.each_with_object({}) do |url, ordered|
    value = results[url]
    ordered[url] = value unless value.nil?
  end
end

# HTML escape function to prevent XSS attacks
def html_escape(text)
  return text unless text.is_a?(String)
  text.gsub('&', '&amp;')
      .gsub('<', '&lt;')
      .gsub('>', '&gt;')
      .gsub('"', '&quot;')
      .gsub("'", '&#39;')
end

# Normalize an item title across feed dialects: RSS2 exposes a String, Atom an
# object with #content. Always returns a String so callers can safely escape it.
def item_title(item)
  raw = item.title
  raw.respond_to?(:content) ? raw.content.to_s : raw.to_s
end

# Normalize an item link across feed dialects: RSS2 exposes a String, Atom an
# object with #href. Always returns a String.
def item_link(item)
  raw = item.link
  return raw.href.to_s if raw.respond_to?(:href)
  return raw.content.to_s if raw.respond_to?(:content)

  raw.to_s
end

# Normalize an item's summary/description across feed dialects (RSS2
# `description`, Atom `summary`/`content`), strip HTML tags and decode entities,
# collapse whitespace, and cap the length. Gives the summarizer real article
# substance (not just the headline) while keeping the content window bounded.
# The raw value is length-capped before the tag regex runs so a pathological
# description can't cause quadratic backtracking, and full tags (e.g. a
# WordPress featured image tag with a long srcset) are stripped whole rather
# than leaking markup. Returns "" when the item has no usable description.
def item_description(item)
  raw = nil
  raw = item.description if item.respond_to?(:description) && item.description
  raw = item.summary if raw.nil? && item.respond_to?(:summary) && item.summary
  raw = item.content if raw.nil? && item.respond_to?(:content) && item.content

  text = (raw.respond_to?(:content) ? raw.content.to_s : raw.to_s)[0, 4000]
  text = CGI.unescapeHTML(text.gsub(/<[^>]*>/, ' ')).gsub(/\s+/, ' ')
  text = text.gsub(/ +([.,;:!?])/, '\1').strip
  text.length > ITEM_DESC_MAX ? "#{text[0, ITEM_DESC_MAX].rstrip}…" : text
end

# Allow only safe URL schemes in generated hrefs so a malicious feed can't inject
# javascript:/data:/vbscript: links. Absolute, protocol-relative, root-relative
# and anchor links pass through; anything else collapses to '#'.
def safe_url(url)
  str = url.to_s.strip
  str.match?(%r{\A(?:https?://|ftp://|mailto:|//|/|\#)}i) ? str : '#'
end

# Bare hostname for a feed URL: strips scheme, leading "www." and any path, so
# "https://www.example.com/rss?x=1" becomes "example.com". Falls back to the
# original string if stripping leaves it empty.
def feed_host(url)
  host = url.to_s.sub(%r{\Ahttps?://}i, '').sub(/\Awww\./i, '').sub(%r{/.*\z}m, '')
  host.empty? ? url.to_s : host
end

# Friendly, short label for a feed source shown in the rendered page: prefer the
# RSS channel title (e.g. "YubaNet"), falling back to the bare hostname when the
# title is missing, the feed is offline, the title itself looks like a URL/domain
# (some feeds title themselves "www.example.com - RSS Results ..."), or the title
# is unreasonably long. Keeps the listing clean and avoids long raw URLs
# overflowing mobile viewports.
def feed_display_name(url, parsed)
  title = (parsed.channel.title.to_s.strip if parsed.respond_to?(:channel) && parsed.channel)
  return feed_host(url) if title.nil? || title.empty? ||
                           title == FEED_OFFLINE_TITLE ||
                           title.match?(%r{\A(?:https?://|www\.)}i)

  title.length > FEED_NAME_MAX ? "#{title[0, FEED_NAME_MAX].rstrip}…" : title
rescue StandardError
  feed_host(url)
end

def sanitize_response(response_body)
  JSON.parse(response_body)
rescue JSON::ParserError => e
  puts "JSON parsing error: #{e.message}"
  nil
end

# Secure version of convert_markdown_links_to_html that prevents ReDoS attacks
def convert_markdown_links_to_html(text)
  # Use a more specific regex that avoids catastrophic backtracking
  # This pattern ensures we match only well-formed markdown links
  text.gsub(/\[([^\]]{1,100})\]\(([^)\s]{1,200})\)/) do |match|
    link_text = html_escape($1)
    url = $2
    # Additional safety: ensure URL uses safe protocols
    if url.match?(/\A(https?|ftp):\/\//)
      "<a href=\"#{html_escape(url)}\">#{link_text}</a>"
    else
      match # Return original text if URL doesn't look safe
    end
  end
end

# Shared GitHub Models endpoint/model used for all AI summaries.
AI_SUMMARY_ENDPOINT = "https://models.inference.ai.azure.com/chat/completions"
AI_SUMMARY_MODEL = "gpt-4o-mini"

# Apply the shared markdown-ish -> HTML formatting used by every summary:
# newlines to <br/>, "## x" to escaped <h2>, markdown links, and **bold**.
def format_summary(text)
  summary = text.gsub("\n", "<br/>")
  summary = summary.gsub(/(##\s*)(.*)/) { "<h2>#{html_escape($2)}</h2>" }
  summary = convert_markdown_links_to_html(summary)
  summary.gsub(/\*\*(.*?)\*\*/) { "<b>#{html_escape($1)}</b>" }
end

# Request a GitHub Models chat completion for a summary. Centralizes the token
# guard, HTTP call, response parsing/formatting and error handling shared by
# every summarize_* method. `context` only affects log wording.
def generate_ai_summary(system_prompt, user_content, context:, temperature:, max_tokens:, top_p:)
  unless ENV['GITHUB_TOKEN']
    puts "No GITHUB_TOKEN provided, skipping AI summarization"
    return "AI summarization unavailable - no API token configured."
  end

  response = HTTParty.post(
    AI_SUMMARY_ENDPOINT,
    headers: {
      "Content-Type" => "application/json",
      "Authorization" => "Bearer #{ENV['GITHUB_TOKEN']}"
    },
    body: {
      "messages": [
        { "role": "system", "content": system_prompt },
        { "role": "user", "content": user_content }
      ],
      "model": AI_SUMMARY_MODEL,
      "temperature": temperature,
      "max_tokens": max_tokens,
      "top_p": top_p
    }.to_json
  )
  parsed_response = sanitize_response(response.body)

  if parsed_response && parsed_response["choices"] && !parsed_response["choices"].empty?
    format_summary(parsed_response["choices"].first["message"]["content"])
  else
    "Summary generation failed - no valid response from AI service."
  end
rescue HTTParty::Error => e
  puts "HTTP error summarizing #{context}: #{e.message}"
  "Summary unavailable due to network error."
rescue => e
  puts "General error summarizing #{context}: #{e.message}"
  "Summary generation failed due to technical error."
end

def summarize_news(feed)
  return "No content available for summarization." if feed.nil?
  # An offline placeholder feed has no real content to summarize; returning nil
  # lets the template hide the per-feed summary box entirely instead of leaking
  # an AI refusal ("I'm unable to access external websites") to visitors.
  return nil if feed_offline?(feed)

  news_content = if feed.is_a?(Array)
                   feed.flat_map { |f| extract_feed_content(f) }.join('. ')
                 else
                   extract_feed_content(feed).join('. ')
                 end
  return "No articles available for summarization." if news_content.empty?

  generate_ai_summary(
    "You are a news editor writing a front-page digest. Summarize the key stories below in under 150 words of clear, factual journalistic prose. Lead with the most important developments and include specific names, places, dates, and figures when present. Do not mention the feed or that you are summarizing. Output only the summary text: no headings, labels, lists, or preamble.",
    news_content[0..4096],
    context: "news",
    temperature: 0.5,
    max_tokens: 300,
    top_p: 1
  )
end

def summarize_overall_news(feeds)
  return "No content available for summarization." if feeds.nil? || feeds.empty?

  # Skip offline placeholders so the bare feed URL never pollutes the
  # front-page summary (or makes the model refuse to summarize it).
  live_feeds = feeds.reject { |feed| feed_offline?(feed) }
  all_content = live_feeds.flat_map { |feed| extract_feed_content(feed) }.join('. ')
  return "No articles available for summarization." if all_content.empty?

  generate_ai_summary(
    "You are the editor of a major newspaper writing the front-page summary across all of today's sources. In under 200 words, synthesize the most important stories, common themes, and significant trends. Explain what happened, who is affected, and why it matters, emphasizing facts and implications over a list of events. Do not mention the feeds or sources themselves. Output only the summary text: no headings, labels, or preamble.",
    all_content[0..6144],
    context: "overall news",
    temperature: 0.4,
    max_tokens: 400,
    top_p: 0.95
  )
end

# Extract content from a feed for summarization: one "Title - description" line
# per item. Includes the article description (real substance) and deliberately
# omits the raw URL, which only wastes tokens and tempts the model to "comment
# on" or "access" the source. Handles offline feeds gracefully.
def extract_feed_content(feed)
  return [] if feed.nil? || !feed.respond_to?(:items) || feed.items.nil?

  feed.items.map do |item|
    title = item_title(item).to_s.strip
    desc = item_description(item)
    desc.empty? ? title : "#{title} - #{desc}"
  end.reject(&:empty?)
rescue => e
  puts "Error extracting feed content: #{e.message}"
  []
end

# Parse YubaNet "Happening Now" HTML into breaking-news entries. Pure (no I/O)
# so it can be unit-tested against fixture HTML without hitting the network.
#
# YubaNet uses WordPress block markup, so entries look like:
#   <p class="wp-block-paragraph"><strong>July 4, 2026 at 9:40 PM </strong>content <a href="…">link</a>.</p>
# The <p> may carry attributes and the content may contain nested tags (e.g.
# <a>). Attributes are allowed and the inner HTML is captured non-greedily and
# bounded (ReDoS-safe), then tags are stripped and HTML entities decoded (so
# "&#8211;" isn't double-escaped once the template re-escapes for output).
def parse_breaking_news(html_content, url)
  entries = []
  return entries unless html_content.is_a?(String)

  html_content.scan(%r{<p[^>]{0,200}>\s*<strong>([^<]{1,200}(?:AM|PM)[^<]{0,50})</strong>\s*(.{1,2000}?)</p>}m) do |timestamp, content|
    clean_content = CGI.unescapeHTML(content.gsub(/<[^>]{1,300}>/, '')).strip
    clean_timestamp = CGI.unescapeHTML(timestamp).strip

    # Skip very short or empty content
    next if clean_content.length < 10

    entries << {
      timestamp: clean_timestamp,
      content: clean_content,
      link: url
    }
  end

  entries
end

# Fetch and parse YubaNet breaking news from featured/now page
def fetch_yubanet_breaking_news
  url = 'https://yubanet.com/featured/now/'
  response = HTTParty.get(url, timeout: 60, headers: { 'User-Agent' => 'rss-firehose feed aggregator' })

  if response.code == 200
    entries = parse_breaking_news(response.body, url)
    puts "Fetched #{entries.size} breaking news entries from YubaNet"
    entries
  else
    puts "Failed to fetch YubaNet breaking news: HTTP #{response.code}"
    []
  end
rescue HTTParty::Error => e
  puts "HTTP error fetching YubaNet breaking news: #{e.message}"
  []
rescue => e
  puts "General error fetching YubaNet breaking news: #{e.message}"
  []
end

# Summarize breaking news content using AI
def summarize_breaking_news(breaking_news)
  return "No breaking news available for summarization." if breaking_news.nil? || breaking_news.empty?

  latest_entries = breaking_news.first(5)
  content_text = latest_entries.map { |entry| "#{entry[:timestamp]}: #{entry[:content]}" }.join('. ')
  return "No breaking news content available for summarization." if content_text.empty?

  generate_ai_summary(
    "You are a breaking-news editor. In under 100 words, summarize the most critical, time-sensitive developments below. Highlight what readers need to know right now, including immediate impacts and any emerging pattern. Use urgent but clear language. Output only the summary text: no headings, labels, or preamble.",
    content_text[0..3072],
    context: "breaking news",
    temperature: 0.3,
    max_tokens: 200,
    top_p: 0.9
  )
end

# Turn an NWS active-alerts API JSON body into a compact, escaped-later list of
# critical alerts. Pure (no I/O) so it can be unit-tested against fixture JSON.
# Keeps only genuinely critical alerts (see NWS_CRITICAL_* ) so routine
# advisories don't dilute the band, dedupes repeated events, and caps the count.
def parse_weather_alerts(json_body)
  data = JSON.parse(json_body.to_s)
  features = data['features']
  return [] unless features.is_a?(Array)

  alerts = features.filter_map do |feature|
    props = feature['properties']
    next unless props.is_a?(Hash)

    event = props['event'].to_s.strip
    next if event.empty?

    severity = props['severity'].to_s
    next unless NWS_CRITICAL_SEVERITIES.include?(severity) || event.match?(NWS_CRITICAL_EVENTS)

    {
      event: event,
      headline: props['headline'].to_s.strip,
      area: props['areaDesc'].to_s.strip,
      severity: severity,
      expires: props['expires'].to_s.strip
    }
  end

  alerts.uniq { |a| [a[:event], a[:area]] }.first(NWS_ALERT_MAX)
rescue JSON::ParserError => e
  puts "Error parsing weather alerts: #{e.message}"
  []
end

# Fetch active NWS alerts for a zone and return the critical subset. Always
# fetched fresh (alerts are time-sensitive, so they are never cached with the
# 6-hour AI bundle) and fails soft to [] so a NWS outage never breaks the page.
def fetch_weather_alerts(zone = NWS_ALERT_ZONE)
  return [] if zone.nil? || zone.empty?

  response = HTTParty.get(
    "#{NWS_ALERTS_ENDPOINT}?zone=#{CGI.escape(zone)}",
    timeout: 30,
    headers: { 'User-Agent' => NWS_USER_AGENT, 'Accept' => 'application/geo+json' }
  )
  unless response.code == 200
    puts "Failed to fetch NWS alerts for #{zone}: HTTP #{response.code}"
    return []
  end

  alerts = parse_weather_alerts(response.body)
  puts "Fetched #{alerts.size} critical NWS alert(s) for #{zone}"
  alerts
rescue HTTParty::Error => e
  puts "HTTP error fetching NWS alerts: #{e.message}"
  []
rescue => e
  puts "General error fetching NWS alerts: #{e.message}"
  []
end

# Cache the full AI summary bundle (overall + per-feed + breaking) as one JSON
# document so a cache hit can restore every summary and make zero AI calls. The
# overall summary is stored under `summary` for backward compatibility with
# older single-summary cache files. Only called when the overall summary is
# usable (see caller), so a fresh cache never persists an error placeholder.
def cache_summaries(overall_summary, feed_summaries, breaking_news_summary)
  return unless overall_summary && !overall_summary.empty?

  begin
    FileUtils.mkdir_p('cache')
    File.open(CACHE_FILE, 'w') do |f|
      f.write({
        timestamp: Time.now.utc.iso8601,
        summary: overall_summary,
        feed_summaries: feed_summaries || {},
        breaking_news_summary: breaking_news_summary
      }.to_json)
    end
    puts "Summaries cached successfully"
  rescue => e
    puts "Warning: Failed to cache summaries: #{e.message}"
  end
end

# Load the cached summary bundle if present and still within the 6h TTL.
# Returns { 'overall' =>, 'feeds' =>, 'breaking' => } or nil on miss/expiry/
# error. Older single-summary cache files (just `summary`) still load — the
# per-feed and breaking parts are simply treated as empty.
def load_cached_summaries
  # Skip cache if force regeneration is requested
  if ENV['FORCE_REGENERATE'] == 'true'
    puts "Force regeneration enabled, skipping cache"
    return nil
  end

  return unless File.exist?(CACHE_FILE)

  begin
    data = JSON.parse(File.read(CACHE_FILE))
    timestamp = Time.parse(data['timestamp'])

    # Check if cache is still valid (6 hours)
    if Time.now.utc - timestamp < 6 * 60 * 60
      puts "Loaded cached summaries from #{timestamp}"
      {
        'overall' => data['summary'],
        'feeds' => data['feed_summaries'] || {},
        'breaking' => data['breaking_news_summary']
      }
    else
      puts "Cached summary expired, will generate new one"
      nil
    end
  rescue JSON::ParserError, ArgumentError => e
    puts "Warning: Error loading cached summary: #{e.message}"
    nil
  rescue => e
    puts "Warning: Unexpected error loading cache: #{e.message}"
    nil
  end
end

# Only run the full render (config logging, feed fetching, AI summaries, file
# output) when executed directly. Requiring/loading this file (e.g. from tests)
# then has no side effects and performs no network I/O.
if __FILE__ == $PROGRAM_NAME
# Validate configuration and log startup info
puts "RSS Firehose starting..."
puts "Title: #{title}"
puts "Description: #{description}"
puts "RSS URLs: #{rss_urls.join(', ')}" if rss_urls.any?
puts "Backup URLs: #{rss_backup_urls.join(', ')}" if rss_backup_urls.any?
puts "GitHub Token: #{ENV['GITHUB_TOKEN'] ? 'configured' : 'not configured (AI summaries disabled)'}"
puts "Analytics UA: #{ENV['ANALYTICS_UA'] ? 'configured' : 'not configured'}"
puts ""

feeds = fetch_feeds(rss_urls)
breaking_news = fetch_yubanet_breaking_news
weather_alerts = fetch_weather_alerts
cached = load_cached_summaries

if cached
  # Reuse every cached summary — a hit makes zero AI calls. (Older caches only
  # hold the overall summary; the per-feed and breaking sections are omitted
  # rather than shown as a placeholder.)
  overall_summary = cached['overall']
  feed_summaries = cached['feeds'] || {}
  breaking_news_summary = cached['breaking']
  puts "Using cached summaries."
else
  puts "Generating summaries for #{feeds.size} feeds..."

  # Every summary is an independent GitHub Models request, so pipeline them all
  # (per-feed + overall + breaking) across the bounded pool instead of making
  # N+2 serial calls. On a 3-feed run this is 5 HTTP round-trips collapsed from
  # sequential to roughly one call's wall-clock.
  jobs = feeds.keys.map { |url| [:feed, url] }
  jobs << [:overall, nil]
  jobs << [:breaking, nil]

  summaries = parallel_map(jobs) do |(kind, url)|
    case kind
    when :feed     then summarize_news(feeds[url])
    when :overall  then summarize_overall_news(feeds.values)
    when :breaking then summarize_breaking_news(breaking_news)
    end
  end

  feed_summaries = feeds.keys.each_with_object({}) do |url, acc|
    acc[url] = summaries[[:feed, url]]
  end
  overall_summary = summaries[[:overall, nil]]
  breaking_news_summary = summaries[[:breaking, nil]]

  # Only cache if we actually got a useful overall summary, so neither an error
  # placeholder nor a degraded "no content" render gets persisted for the TTL.
  if overall_summary && !PLACEHOLDER_SUMMARIES.include?(overall_summary) &&
     !overall_summary.include?("unavailable") && !overall_summary.include?("failed")
    cache_summaries(overall_summary, feed_summaries, breaking_news_summary)
    puts "Generated and cached new summaries."
  else
    puts "Generated summaries but not caching due to errors."
  end
end

puts "Overall Summary: #{overall_summary}"

begin
  render_manifest
  render_html(feeds, overall_summary, feed_summaries, breaking_news, breaking_news_summary, weather_alerts)
  puts "Successfully rendered HTML and manifest files."
rescue => e
  puts "Error during rendering process: #{e.message}"
  puts "Backtrace: #{e.backtrace.first(5).join("\n")}"
end
end
