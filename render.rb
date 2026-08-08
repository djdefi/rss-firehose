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

# Optional per-feed item filters: keep only items for which the lambda returns
# true. InciWeb's RSS is national; we keep just California/Nevada incidents so
# the regional Fire section stays on-topic. Item titles are prefixed with the
# 2-letter state code (e.g. "CACNP …" / "NVELD …") and the description carries
# "State: California".
FEED_ITEM_FILTERS = {
  'https://inciweb.wildfire.gov/incidents/rss.xml' => lambda do |item|
    "#{item.title}".match?(/\A(?:CA|NV)/) ||
      "#{item.description}".match?(/State:\s*(?:California|Nevada)/)
  end
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

# Shared newsroom contract for all summaries. These rules are intentionally
# explicit because small local models need stronger grounding than large hosted
# models.
SUMMARY_PROMPT_GUARDRAILS = <<~PROMPT.strip.freeze
  Use only facts stated in the supplied items. Do not invent, infer, or connect separate items.
  Each bracketed ITEM is independent unless its own text explicitly says otherwise.
  Preserve names, places, dates, numbers, and operational status verbs exactly as written.
  Treat jokes, asides, rhetorical questions, and parenthetical comments as non-factual and omit them.
  Ignore slogans, teasers, calls to action, and promotional headline fragments unless the DESCRIPTION states concrete news facts.
  Omit incomplete or truncated text, including text ending in an ellipsis. Never complete a cut-off phrase.
  Do not add severity, importance, or promotional adjectives unless they appear in the supplied item.
  Do not describe what residents know, feel, expect, or face unless an item states it.
  Do not mention the feed, source, article, supplied text, or that you are summarizing.
  Never begin with "The text", "This article", "These stories", "The following", or "In summary".
  Do not end with a general sentence about what the stories reflect, highlight, or demonstrate.
  Avoid filler such as "recent updates", "meanwhile", "additionally", "highlights", "showcases", "shines", or "makes headlines".
  Return exactly one plain-text paragraph with no label, markdown, HTML, headings, bullets, links, or line breaks.
PROMPT

NEWS_SUMMARY_PROMPT = <<~PROMPT.strip.freeze
  Write a local-news digest of at most 120 words.
  The first sentence must report a specific event with a named subject and action, not announce that updates or stories exist.
  Open with the most recent or consequential development, then briefly include only closely related or important items.
  Use direct declarative sentences and active voice. If the items are thin or repetitive, write less rather than padding.
  #{SUMMARY_PROMPT_GUARDRAILS}
PROMPT

OVERALL_SUMMARY_PROMPT = <<~PROMPT.strip.freeze
  Write a front-page local-news digest of at most 150 words.
  The first sentence must report a specific event with a named subject and action, not announce a digest or list of updates.
  Lead with the most consequential development, then summarize other important developments in descending importance.
  State concrete facts and clearly stated local impacts. Do not merge unrelated items into a single claim or invent a theme.
  Use direct declarative sentences and active voice. If coverage is sparse, write less rather than padding.
  #{SUMMARY_PROMPT_GUARDRAILS}
PROMPT

GROUNDED_FACTS_PROMPT = <<~PROMPT.strip.freeze
  Extract concise news facts from independently labeled items.
  Return only a JSON object with this shape:
  {"facts":[{"item":1,"sentence":"One complete factual sentence."}]}
  Write at most one sentence of 35 words per usable item. Use the ITEM number exactly.
  Every sentence must describe only its matching ITEM. Never combine names, numbers, dates, places, or actions from different items.
  Prefer concrete facts from DESCRIPTION. Use TITLE only to clarify the same item.
  Report the newest concrete action, decision, result, or operational status. For a live incident, include its latest stated size or status instead of merely naming its location.
  Do not merely restate a headline or introductory phrase. Avoid vague constructions such as "highlights", "showcases", "lays out", or "a look at".
  Skip items that contain only a slogan, teaser, list of headlines, editorial note, or incomplete text.
  Preserve every name, place, date, number, numeric format, and operational status exactly as supplied.
  Do not add facts, context, transitions, labels, markdown, commentary, or keys other than "facts", "item", and "sentence".
PROMPT

BREAKING_SUMMARY_PROMPT = <<~PROMPT.strip.freeze
  Write a breaking-news update of at most 70 words.
  The first sentence must summarize the item labeled LATEST UPDATE.
  Use only the LATEST UPDATE; the update list below the summary covers earlier events.
  Prefer its original nouns and verbs over paraphrasing.
  Do not add severity words such as "major" unless the latest item uses them.
  Keep status verbs exactly as written; for example, never change "releasing" to "deploying".
  Include a time only when it appears in the supplied item. Use terse, direct declarative sentences.
  #{SUMMARY_PROMPT_GUARDRAILS}
PROMPT

# Maximum length of a friendly feed name before it is truncated with an
# ellipsis (see feed_display_name), so a long channel title can't dominate the
# layout or reintroduce horizontal overflow on narrow screens.
FEED_NAME_MAX = 40

# Maximum length of a single item's description fed to the summarizer (see
# item_description). Caps how much one verbose article can consume of the
# token-bounded content window, so several items still fit and the AI gets
# breadth as well as depth.
ITEM_DESC_MAX = 400
SUMMARY_ITEMS_PER_FEED = 6
OVERALL_ITEMS_PER_FEED = 2
BREAKING_SUMMARY_ITEMS = 1

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

# Feeds for the secondary "Regional & Fire" page (Truckee/Tahoe outlets +
# InciWeb fire incidents). Kept off the lean main page and off by default so
# the test suite stays hermetic/fast: enabled only when RSS_REGIONAL_URLS is set
# (comma-separated, takes precedence) or RENDER_REGIONAL=1 selects urls-regional.txt.
# The deploy workflow sets RENDER_REGIONAL=1. Every listed feed must be
# runner-verified (many regional feeds are datacenter-IP-blocked).
def regional_urls
  raw = if ENV['RSS_REGIONAL_URLS']
          ENV['RSS_REGIONAL_URLS'].split(',')
        elsif ENV['RENDER_REGIONAL'] == '1' && File.exist?('urls-regional.txt')
          File.readlines('urls-regional.txt')
        else
          []
        end
  raw.map(&:strip).reject(&:empty?).select { |url| url.match?(%r{\Ahttps?://}i) }
end

def description
  desc = ENV['RSS_DESCRIPTION'] || 'View the latest news.'
  desc.strip.empty? ? 'View the latest news.' : desc
end

def analytics_ua
  ENV['ANALYTICS_UA']
end

# Render a feed page from the shared template. output_path/page_title/show_nav
# let the same template drive both the main index and the secondary regional
# page; on the main page they default so the output is unchanged. show_nav emits
# the small two-link inter-page nav (static text, so it passes a11y linting).
def render_html(feeds, overall_summary, feed_summaries, breaking_news = [], breaking_news_summary = nil, weather_alerts = [],
                output_path: 'public/index.html', page_title: nil, show_nav: false)
  begin
    html = File.open('templates/index.html.erb').read
    template = ERB.new(html, trim_mode: '-')
    File.open(output_path, 'w') do |f|
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
      apply_item_filter(url, feed(url))
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

# Apply any configured FEED_ITEM_FILTERS to a parsed feed in place, dropping the
# items the filter rejects. No-op for feeds without a filter or without items,
# so it's safe to call on every fetched feed.
def apply_item_filter(url, parsed)
  filter = FEED_ITEM_FILTERS[url]
  return parsed unless filter && parsed.respond_to?(:items) && parsed.items

  parsed.items.delete_if { |item| !filter.call(item) }
  parsed
rescue StandardError => e
  puts "Warning: item filter failed for '#{url}': #{e.message}"
  parsed
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
# collapse whitespace, and retain only complete text within the length cap.
# Gives the summarizer real article substance (not just the headline) while
# keeping the content window bounded.
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
  return text if text.length <= ITEM_DESC_MAX && !text.end_with?('…') && !text.end_with?('...')

  complete_sentences = split_summary_sentences(text).select do |sentence|
    sentence.match?(/[.!?]\z/) && !sentence.end_with?('…') && !sentence.end_with?('...')
  end
  selected = []
  complete_sentences.each do |sentence|
    candidate = (selected + [sentence]).join(' ')
    break if candidate.length > ITEM_DESC_MAX

    selected << sentence
  end
  selected.join(' ')
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

AI_SUMMARY_MODEL = 'lfm2.5-2.6b'
SUMMARY_PIPELINE_VERSION = 'grounded-v3'

def configured_ai_model
  ENV.fetch('AI_MODEL', AI_SUMMARY_MODEL)
end

# Enforce the one-paragraph plain-text output contract before HTML rendering.
# The prefix cleanup is a deterministic backstop for common small-model
# preambles that the prompt explicitly forbids.
def split_summary_sentences(text)
  chars = text.each_char.to_a
  sentences = []
  start_index = 0

  chars.each_index do |index|
    next unless ['.', '!', '?'].include?(chars[index])
    next unless index == chars.length - 1 || chars[index + 1].strip.empty?

    sentence = chars[start_index..index].join.strip
    sentences << sentence unless sentence.empty?
    start_index = index + 1
  end

  tail = chars[start_index..]&.join.to_s.strip
  sentences << tail unless tail.empty?
  sentences
end

def truncate_summary_sentences(text, max_words)
  return text if max_words.nil? || text.split.size <= max_words

  sentences = split_summary_sentences(text)
  selected = []
  word_count = 0
  sentences.each do |sentence|
    sentence_words = sentence.split.size
    break if word_count + sentence_words > max_words

    selected << sentence
    word_count += sentence_words
  end
  return selected.join(' ') unless selected.empty?

  "#{text.split.first(max_words).join(' ').sub(/[,:;]\z/, '')}."
end

def strip_generic_summary_closer(summary)
  sentences = split_summary_sentences(summary)
  return summary if sentences.length < 2

  closer = sentences.last.downcase
  generic_starts = [
    'these developments reflect',
    'these developments highlight',
    'these developments show',
    'these developments demonstrate',
    'these stories reflect',
    'these stories highlight',
    'these stories show',
    'these stories demonstrate',
    'these updates reflect',
    'these updates highlight',
    'these updates show',
    'these updates demonstrate',
    'those developments reflect',
    'those stories reflect',
    'those updates reflect'
  ]
  return summary unless generic_starts.any? { |prefix| closer.start_with?(prefix) }

  sentences[0...-1].join(' ')
end

def strip_incomplete_summary_sentences(summary)
  sentences = split_summary_sentences(summary)
  sentences.reject! { |sentence| sentence.include?('…') || sentence.include?('...') }
  sentences.pop while sentences.length > 1 && !sentences.last.match?(/[.!?]\z/)
  sentences.join(' ')
end

def deduplicate_summary_sentences(summary)
  seen = {}
  split_summary_sentences(summary).each_with_object([]) do |sentence, unique|
    normalized = sentence.downcase.split.join(' ')
    next if seen[normalized]

    seen[normalized] = true
    unique << sentence
  end.join(' ')
end

def format_summary(text, max_words: nil)
  summary = text.to_s.split.join(' ')
  summary = summary.sub(/\A(?:summary:\s*)/i, '')
  summary = summary.sub(/\Athe (?:supplied )?text (?:highlights|describes|reports|covers|notes|discusses)\s+/i, '')
  summary = summary.sub(/\Arecent updates (?:highlight|include)\s+/i, '')
  summary = summary.sub(/\A[^.:]{1,80}\bis seeing several key updates:\s*/i, '')
  summary = strip_incomplete_summary_sentences(summary)
  summary = deduplicate_summary_sentences(summary)
  summary = strip_generic_summary_closer(summary)
  summary = summary.gsub(/\[([^\]]{1,100})\]\([^)[:space:]]{1,200}\)/, '\1')
  summary = summary.gsub(/\*\*([^*]{1,200})\*\*/, '\1')
  summary = summary.sub(/\A\#{1,6}\s*/, '')
  summary = summary.sub(/\A([a-z])/) { Regexp.last_match(1).upcase }
  summary = truncate_summary_sentences(summary, max_words)
  html_escape(summary.strip)
end

# Request a chat completion from the local llama.cpp server started by the
# Pages workflow. No API key or hosted inference service is required.
def request_ai_completion(system_prompt, user_content, context:, temperature:, max_tokens:, top_p:,
                          response_format: nil)
  endpoint = ENV['AI_API_ENDPOINT'].to_s.strip
  if endpoint.empty?
    puts "No local AI endpoint configured, skipping AI summarization"
    return { error: "AI summarization unavailable - local model not configured." }
  end

  headers = { "Content-Type" => "application/json" }
  request_body = {
    "messages": [
      { "role": "system", "content": system_prompt },
      { "role": "user", "content": user_content }
    ],
    "model": configured_ai_model,
    "temperature": temperature,
    "max_tokens": max_tokens,
    "top_p": top_p
  }
  request_body["response_format"] = response_format if response_format

  response = HTTParty.post(
    endpoint,
    headers: headers,
    timeout: (ENV['AI_REQUEST_TIMEOUT'] || '180').to_i,
    body: request_body.to_json
  )
  if !response.success? && response_format
    puts "AI service rejected structured output for #{context}; retrying with prompt-enforced JSON"
    request_body.delete("response_format")
    response = HTTParty.post(
      endpoint,
      headers: headers,
      timeout: (ENV['AI_REQUEST_TIMEOUT'] || '180').to_i,
      body: request_body.to_json
    )
  end
  unless response.success?
    puts "AI service returned HTTP #{response.code} while summarizing #{context}"
    return { error: "Summary generation failed - AI service returned HTTP #{response.code}." }
  end

  parsed_response = sanitize_response(response.body)
  content = parsed_response&.dig("choices", 0, "message", "content")
  return { error: "Summary generation failed - no valid response from AI service." } if content.to_s.strip.empty?

  { content: content.to_s }
rescue HTTParty::Error => e
  puts "HTTP error summarizing #{context}: #{e.message}"
  { error: "Summary unavailable due to network error." }
rescue => e
  puts "General error summarizing #{context}: #{e.message}"
  { error: "Summary generation failed due to technical error." }
end

def generate_ai_summary(system_prompt, user_content, context:, temperature:, max_tokens:, top_p:, max_words:)
  result = request_ai_completion(
    system_prompt,
    user_content,
    context: context,
    temperature: temperature,
    max_tokens: max_tokens,
    top_p: top_p
  )
  return result[:error] if result[:error]

  format_summary(result[:content], max_words: max_words)
end

def summary_number_tokens(text)
  text.to_s.scan(/\d+(?:[.,]\d+)*/).map { |number| number.delete(',') }
end

def valid_grounded_fact?(sentence, source)
  return false if sentence.empty? || sentence.include?('…') || sentence.include?('...')
  return false unless sentence.match?(/[.!?]\z/)
  return false unless split_summary_sentences(sentence).length == 1
  return false if sentence.split.length > 35
  return false if sentence.match?(/\b(?:a look at|highlights|lays out|located on|questionable origin story|showcases)\b/i)
  return false if sentence.match?(/\b(?:you|your)\b/i)

  (summary_number_tokens(sentence) - summary_number_tokens(source)).empty?
end

def parse_grounded_facts(content, lines)
  parsed = JSON.parse(content.to_s.strip)
  facts = parsed['facts']
  return [] unless facts.is_a?(Array)

  seen = {}
  facts.filter_map do |fact|
    next unless fact.is_a?(Hash)

    item_number = fact['item']
    sentence = fact['sentence'].to_s.split.join(' ')
    next unless item_number.is_a?(Integer) && item_number.between?(1, lines.length)
    next if seen[item_number] || !valid_grounded_fact?(sentence, lines[item_number - 1])

    seen[item_number] = true
    sentence
  end
rescue JSON::ParserError => e
  puts "Grounded fact JSON parsing error: #{e.message}"
  []
end

def generate_grounded_facts(lines, context:)
  return { facts: [], error: "No articles available for summarization." } if lines.empty?

  errors = []
  facts = lines.each_with_index.filter_map do |line, index|
    result = request_ai_completion(
      GROUNDED_FACTS_PROMPT,
      labeled_summary_content([line], 1024),
      context: "#{context} item #{index + 1}",
      temperature: 0.0,
      max_tokens: 120,
      top_p: 0.8,
      response_format: { "type" => "json_object" }
    )
    if result[:error]
      errors << result[:error]
      next
    end

    parse_grounded_facts(result[:content], [line]).first
  end
  if facts.empty?
    { facts: [], error: errors.first || "Summary generation failed - no grounded facts returned." }
  else
    { facts: facts, error: nil }
  end
end

def assemble_grounded_summary(facts, max_words:)
  return "No articles available for summarization." if facts.empty?

  format_summary(facts.join(' '), max_words: max_words)
end

def interleave_grounded_facts(fact_sets)
  max_size = fact_sets.map(&:length).max.to_i
  (0...max_size).flat_map do |index|
    fact_sets.filter_map { |facts| facts[index] }
  end
end

def assemble_fact_results(results, keys, max_words:)
  fact_sets = keys.filter_map do |key|
    result = results[key]
    result[:facts].first(3) unless result[:error]
  end
  facts = interleave_grounded_facts(fact_sets)
  facts = split_summary_sentences(deduplicate_summary_sentences(facts.join(' ')))
  return "Summary generation failed - no grounded facts returned." if facts.empty?

  assemble_grounded_summary(facts, max_words: max_words)
end

def summarize_news(feed)
  return "No content available for summarization." if feed.nil?
  # An offline placeholder feed has no real content to summarize; returning nil
  # lets the template hide the per-feed summary box entirely instead of leaking
  # an AI refusal ("I'm unable to access external websites") to visitors.
  return nil if feed_offline?(feed)

  lines = if feed.is_a?(Array)
            feed.flat_map { |f| extract_feed_content(f) }
          else
            extract_feed_content(feed)
          end
  result = generate_grounded_facts(deduplicate_summary_lines(lines), context: "news")
  return result[:error] if result[:error]

  assemble_grounded_summary(result[:facts], max_words: 120)
end

def summarize_overall_news(feeds)
  return "No content available for summarization." if feeds.nil? || feeds.empty?

  # Skip offline placeholders so the bare feed URL never pollutes the
  # front-page summary (or makes the model refuse to summarize it).
  live_feeds = feeds.reject { |feed| feed_offline?(feed) }
  all_lines = live_feeds.flat_map { |feed| extract_feed_content(feed, limit: OVERALL_ITEMS_PER_FEED) }
  result = generate_grounded_facts(deduplicate_summary_lines(all_lines), context: "overall news")
  return result[:error] if result[:error]

  assemble_grounded_summary(result[:facts], max_words: 150)
end

# Normalize an item timestamp across RSS and Atom dialects.
def item_published_at(item)
  raw = if item.respond_to?(:date) && item.date
          item.date
        elsif item.respond_to?(:pubDate) && item.pubDate
          item.pubDate
        elsif item.respond_to?(:published) && item.published
          item.published
        elsif item.respond_to?(:updated) && item.updated
          item.updated
        end
  raw = raw.content if raw.respond_to?(:content)
  raw.is_a?(Time) ? raw : Time.parse(raw.to_s)
rescue ArgumentError, TypeError
  nil
end

# Extract recent items as "Title - description" lines. Dated entries are sorted
# newest first; undated entries retain feed order. URLs are deliberately omitted.
def extract_feed_content(feed, limit: SUMMARY_ITEMS_PER_FEED)
  return [] if feed.nil? || !feed.respond_to?(:items) || feed.items.nil?

  sorted_items = feed.items.each_with_index.sort_by do |item, index|
    published_at = item_published_at(item)
    published_at ? [0, -published_at.to_f, index] : [1, 0, index]
  end.map(&:first)

  sorted_items.filter_map do |item|
    title = CGI.unescapeHTML(item_title(item).to_s).split.join(' ')
    desc = item_description(item)
    next if composite_digest_title?(title)
    next if editorial_note_only?(desc)
    next if desc.empty? && promotional_title?(title)

    text = desc.empty? ? title : "#{title} - #{desc}"
    text unless text.empty?
  end.first(limit)
rescue => e
  puts "Error extracting feed content: #{e.message}"
  []
end

# Join only complete item lines within a character budget so model input never
# ends with a truncated headline or sentence fragment.
def bounded_summary_content(lines, max_chars)
  selected = []
  length = 0
  lines.each do |line|
    added_length = line.length + (selected.empty? ? 0 : 2)
    break if length + added_length > max_chars

    selected << line
    length += added_length
  end
  selected.join('. ')
end

def labeled_summary_content(lines, max_chars)
  labeled_lines = lines.each_with_index.map do |line, index|
    title, desc = line.split(' - ', 2)
    fields = ["[ITEM #{index + 1}] TITLE: #{title}"]
    fields << "DESCRIPTION: #{desc}" unless desc.to_s.empty?
    fields.join(' | ')
  end
  bounded_summary_content(labeled_lines, max_chars)
end

def promotional_title?(title)
  title.include?('!') &&
    title.match?(/\b(?:apply|attend|buy|donate|join|register|subscribe|support|vote)\b/i)
end

def composite_digest_title?(title)
  title.scan(/;\s+\S/).length >= 2 || title.match?(/;\s*more\z/i)
end

def editorial_note_only?(description)
  description.match?(/\Aeditor(?:'|’)?s note\b/i)
end

def deduplicate_summary_lines(lines)
  seen = {}
  lines.each_with_object([]) do |line, unique|
    title = line.split(' - ', 2).first.to_s.downcase.gsub(/\s+/, ' ').strip
    next if title.empty? || seen[title]

    seen[title] = true
    unique << line
  end
end

def breaking_summary_content(breaking_news)
  entries = breaking_news.first(BREAKING_SUMMARY_ITEMS)
  lines = entries.map do |entry|
    "LATEST UPDATE — #{entry[:timestamp]}: #{entry[:content]}"
  end
  bounded_summary_content(lines, 3072)
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

# Breaking updates remain verbatim. The local 1.2B model repeatedly changed
# operational status and merged unrelated incidents, which is unacceptable on
# the site's most time-sensitive surface.
def summarize_breaking_news(breaking_news)
  return "No breaking news available for summarization." if breaking_news.nil? || breaking_news.empty?
  nil
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
def cache_summaries(overall_summary, feed_summaries, breaking_news_summary, regional_summary = nil)
  return unless overall_summary && !overall_summary.empty?

  begin
    FileUtils.mkdir_p('cache')
    File.open(CACHE_FILE, 'w') do |f|
      f.write({
        timestamp: Time.now.utc.iso8601,
        model: configured_ai_model,
        pipeline: SUMMARY_PIPELINE_VERSION,
        summary: overall_summary,
        feed_summaries: feed_summaries || {},
        breaking_news_summary: breaking_news_summary,
        regional_summary: regional_summary
      }.to_json)
    end
    puts "Summaries cached successfully"
  rescue => e
    puts "Warning: Failed to cache summaries: #{e.message}"
  end
end

# True when an AI summary is genuine content, not an empty / placeholder / error
# string. Lets callers hide the summary box (and skip caching) instead of
# surfacing "No content available…" or an "unavailable"/"failed" error.
def usable_summary?(summary)
  summary && !summary.empty? &&
    !PLACEHOLDER_SUMMARIES.include?(summary) &&
    !summary.include?('unavailable') && !summary.include?('failed')
end

# Load the cached summary bundle if present and still within the 6h TTL.
# Returns { 'overall' =>, 'feeds' =>, 'breaking' =>, 'regional' => } or nil on
# miss/expiry/error. Older cache files (missing newer keys) still load — the
# absent parts are simply treated as empty.
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
    if !ENV['AI_API_ENDPOINT'].to_s.strip.empty? && data['model'] != configured_ai_model
      puts "Cached summaries use #{data['model'] || 'an unknown model'}, regenerating with #{configured_ai_model}"
      return nil
    end
    if !ENV['AI_API_ENDPOINT'].to_s.strip.empty? && data['pipeline'] != SUMMARY_PIPELINE_VERSION
      puts "Cached summaries use an older pipeline, regenerating grounded facts"
      return nil
    end

    # Check if cache is still valid (6 hours)
    if Time.now.utc - timestamp < 6 * 60 * 60
      puts "Loaded cached summaries from #{timestamp}"
      {
        'overall' => data['summary'],
        'feeds' => data['feed_summaries'] || {},
        'breaking' => data['breaking_news_summary'],
        'regional' => data['regional_summary']
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
puts "Local AI: #{ENV['AI_API_ENDPOINT'].to_s.strip.empty? ? 'not configured (summaries disabled)' : configured_ai_model}"
puts "Analytics UA: #{ENV['ANALYTICS_UA'] ? 'configured' : 'not configured'}"
puts ""

feeds = fetch_feeds(rss_urls)
regional = regional_urls
regional_feeds = regional.any? ? fetch_feeds(regional) : {}
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
  regional_summary = cached['regional']
  puts "Using cached summaries."
else
  puts "Generating summaries for #{feeds.size} feeds..."

  # Extract independently keyed facts for each feed in parallel. Feed summaries
  # and the front-page summary are assembled from the same validated sentences,
  # so the overall digest cannot invent new cross-feed relationships.
  jobs = feeds.keys.map { |url| [:feed_facts, url] }
  jobs.concat(regional_feeds.keys.map { |url| [:regional_facts, url] })
  jobs << [:breaking, nil]

  summaries = parallel_map(jobs) do |(kind, url)|
    case kind
    when :feed_facts
      lines = deduplicate_summary_lines(extract_feed_content(feeds[url]))
      generate_grounded_facts(lines, context: "feed #{url}")
    when :regional_facts
      lines = deduplicate_summary_lines(extract_feed_content(regional_feeds[url], limit: OVERALL_ITEMS_PER_FEED))
      generate_grounded_facts(lines, context: "regional feed #{url}")
    when :breaking then summarize_breaking_news(breaking_news)
    end
  end

  feed_fact_results = feeds.keys.each_with_object({}) do |url, acc|
    acc[url] = summaries[[:feed_facts, url]]
  end
  feed_summaries = feeds.keys.each_with_object({}) do |url, acc|
    result = feed_fact_results[url]
    acc[url] = result[:error] || assemble_grounded_summary(result[:facts], max_words: 120)
  end
  overall_summary = assemble_fact_results(feed_fact_results, feeds.keys, max_words: 150)
  breaking_news_summary = summaries[[:breaking, nil]]
  regional_fact_results = regional_feeds.keys.each_with_object({}) do |url, acc|
    acc[url] = summaries[[:regional_facts, url]]
  end
  regional_summary = if regional_feeds.any?
                       assemble_fact_results(regional_fact_results, regional_feeds.keys, max_words: 150)
                     end

  # Only cache if we actually got a useful overall summary, so neither an error
  # placeholder nor a degraded "no content" render gets persisted for the TTL.
  if usable_summary?(overall_summary)
    cache_summaries(overall_summary, feed_summaries, breaking_news_summary, regional_summary)
    puts "Generated and cached new summaries."
  else
    puts "Generated summaries but not caching due to errors."
  end
end

puts "Overall Summary: #{overall_summary}"

begin
  render_manifest

  render_html(feeds, overall_summary, feed_summaries, breaking_news, breaking_news_summary, weather_alerts,
              show_nav: regional.any?)

  if regional.any?
    puts "Rendering regional page for #{regional.size} feeds..."
    render_html(regional_feeds, (regional_summary if usable_summary?(regional_summary)), {}, [], nil, [],
                output_path: 'public/regional.html',
                page_title: "#{title} · Regional & Fire",
                show_nav: true)
  end

  puts "Successfully rendered HTML and manifest files."
rescue => e
  puts "Error during rendering process: #{e.message}"
  puts "Backtrace: #{e.backtrace.first(5).join("\n")}"
end
end
