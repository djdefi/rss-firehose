#!/usr/bin/env ruby
# frozen_string_literal: true

require 'erb'
require 'rss'
require 'httparty'
require 'json'
require 'time'
require 'fileutils'

CACHE_FILE = 'cache/ai_summary_cache.json'

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

def render_html(overall_summary, feed_summaries, breaking_news = [], breaking_news_summary = nil)
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

# Get the feeds and parse them. We don't validate because some feeds are
# malformed slightly and break the parser.
def feed(url)
  begin
    response = HTTParty.get(url, timeout: 60, headers: { 'User-Agent' => 'rss-firehose feed aggregator' })
    rss_content = RSS::Parser.parse(response.body, false) if response.code == 200
    # If the feed is empty or nil, retry once
    if (rss_content.nil? || rss_content.items.empty?)
      puts "Feed from '#{url}' returned no items, retrying once..."
      response = HTTParty.get(url, timeout: 60, headers: { 'User-Agent' => 'rss-firehose feed aggregator' })
      rss_content = RSS::Parser.parse(response.body, false) if response.code == 200
    end
    # If still empty or nil, create a placeholder RSS object
    if rss_content.nil? || rss_content.items.empty?
      puts "Feed from '#{url}' failed after retry. Response Code: #{response.code}"
      puts "Response Body: #{response.body[0..500]}" # Log first 500 characters of the response body for debugging
      rss_content = create_offline_feed(url)
    end

    rss_content
  rescue HTTParty::Error, RSS::Error => e
    puts "Error fetching or parsing feed from '#{url}': #{e.class} - #{e.message}"
    create_offline_feed(url)
  rescue => e
    puts "General error with feed '#{url}': #{e.message}"
    create_offline_feed(url)
  end
end

# Create a placeholder RSS feed object for offline/failed feeds
def create_offline_feed(url)
  rss_content = RSS::Rss.new('2.0')
  rss_content.channel = RSS::Rss::Channel.new
  rss_content.channel.title = "Feed currently offline"
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

# HTML escape function to prevent XSS attacks
def html_escape(text)
  return text unless text.is_a?(String)
  text.gsub('&', '&amp;')
      .gsub('<', '&lt;')
      .gsub('>', '&gt;')
      .gsub('"', '&quot;')
      .gsub("'", '&#39;')
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

def summarize_news(feed)
  return "No content available for summarization." if feed.nil?
  
  begin
    news_content = if feed.is_a?(Array)
                     feed.flat_map { |f| extract_feed_content(f) }.join('. ')
                   else
                     extract_feed_content(feed).join('. ')
                   end
    
    return "No articles available for summarization." if news_content.empty?
    
    # Skip AI summarization if no GITHUB_TOKEN is provided
    unless ENV['GITHUB_TOKEN']
      puts "No GITHUB_TOKEN provided, skipping AI summarization"
      return "AI summarization unavailable - no API token configured."
    end
    
    response = HTTParty.post(
      "https://models.inference.ai.azure.com/chat/completions",
      headers: {
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{ENV['GITHUB_TOKEN']}"
      },
      body: {
        "messages": [
          {
            "role": "system",
            "content": "Summarize the key news stories and developments in under 150 words. Focus on the actual news events, facts, and analysis presented in the content. Write as if creating a front-page news digest. Use clear, journalistic language with varied sentence structure. Include specific names, places, dates, and substantive details when available. Avoid commenting on the news source itself."
          },
          {
            "role": "user",
            "content": news_content[0..4096] # Adjust to fit within token limits
          }
        ],
        "model": "gpt-4o-mini",
        "temperature": 0.6,
        "max_tokens": 300,
        "top_p": 1
      }.to_json
    )
    parsed_response = sanitize_response(response.body)
    
    if parsed_response && parsed_response["choices"] && !parsed_response["choices"].empty?
      summary = parsed_response["choices"].first["message"]["content"]
      summary = summary.gsub("\n", "<br/>") # Format for HTML line breaks
      summary = summary.gsub(/(##\s*)(.*)/) { |match| "<h2>#{html_escape($2)}</h2>" } # Format headers with escaping
      summary = convert_markdown_links_to_html(summary) # Convert Markdown links to HTML
      summary = summary.gsub(/\*\*(.*?)\*\*/) { |match| "<b>#{html_escape($1)}</b>" } # Convert **text** to bold with proper escaping
      summary
    else
      "Summary generation failed - no valid response from AI service."
    end
  rescue HTTParty::Error => e
    puts "HTTP error summarizing news: #{e.message}"
    "Summary unavailable due to network error."
  rescue => e
    puts "General error summarizing news: #{e.message}"
    "Summary generation failed due to technical error."
  end
end

def summarize_overall_news(feeds)
  return "No content available for summarization." if feeds.nil? || feeds.empty?
  
  begin
    all_content = feeds.flat_map { |feed| extract_feed_content(feed) }.join('. ')
    
    return "No articles available for summarization." if all_content.empty?
    
    # Skip AI summarization if no GITHUB_TOKEN is provided
    unless ENV['GITHUB_TOKEN']
      puts "No GITHUB_TOKEN provided, skipping AI summarization"
      return "AI summarization unavailable - no API token configured."
    end
    
    response = HTTParty.post(
      "https://models.inference.ai.azure.com/chat/completions",
      headers: {
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{ENV['GITHUB_TOKEN']}"
      },
      body: {
        "messages": [
          {
            "role": "system",
            "content": "Create a front-page news summary under 200 words covering the major news stories and developments from all sources. Identify the most important stories, key themes, and significant trends. Write as a professional news editor would for a major newspaper's front page. Focus on what happened, who it affects, and why it matters. Use clear, authoritative journalistic language. Emphasize facts, context, and implications rather than just listing events. Avoid any commentary about news sources themselves."
          },
          {
            "role": "user",
            "content": all_content[0..6144] # Larger content window for overall analysis
          }
        ],
        "model": "gpt-4o-mini",
        "temperature": 0.4,
        "max_tokens": 400,
        "top_p": 0.95
      }.to_json
    )
    parsed_response = sanitize_response(response.body)
    
    if parsed_response && parsed_response["choices"] && !parsed_response["choices"].empty?
      summary = parsed_response["choices"].first["message"]["content"]
      summary = summary.gsub("\n", "<br/>") # Format for HTML line breaks
      summary = summary.gsub(/(##\s*)(.*)/) { |match| "<h2>#{html_escape($2)}</h2>" } # Format headers with escaping
      summary = convert_markdown_links_to_html(summary) # Convert Markdown links to HTML
      summary = summary.gsub(/\*\*(.*?)\*\*/) { |match| "<b>#{html_escape($1)}</b>" } # Convert **text** to bold with proper escaping
      summary
    else
      "Summary generation failed - no valid response from AI service."
    end
  rescue HTTParty::Error => e
    puts "HTTP error summarizing overall news: #{e.message}"
    "Summary unavailable due to network error."
  rescue => e
    puts "General error summarizing overall news: #{e.message}"
    "Summary generation failed due to technical error."
  end
end

# Extract content from a feed, handling offline feeds gracefully
def extract_feed_content(feed)
  return [] if feed.nil? || !feed.respond_to?(:items) || feed.items.nil?
  
  feed.items.map { |item| "#{item.title} (#{item.link})" }.compact
rescue => e
  puts "Error extracting feed content: #{e.message}"
  []
end

# Fetch and parse YubaNet breaking news from featured/now page
def fetch_yubanet_breaking_news
  begin
    url = 'https://yubanet.com/featured/now/'
    response = HTTParty.get(url, timeout: 60, headers: { 'User-Agent' => 'rss-firehose feed aggregator' })
    
    if response.code == 200
      # Extract breaking news entries with timestamps
      entries = []
      html_content = response.body
      
      # Look for patterns like: <p><strong>August 13, 2025 at 2:44 PM</strong> The power outage...
      # Use a safer regex pattern to avoid ReDoS vulnerabilities
      html_content.scan(/<p><strong>([^<]{1,200}(?:AM|PM)[^<]{0,50})<\/strong>\s*([^<]{1,2000})<\/p>/m) do |timestamp, content|
        # Clean up the content by removing HTML tags and extra whitespace
        # Use gsub with a character class to safely remove HTML tags
        clean_content = content.gsub(/<[^>]{1,50}>/, '').strip
        clean_timestamp = timestamp.strip
        
        # Skip very short or empty content
        next if clean_content.length < 10
        
        entries << {
          timestamp: clean_timestamp,
          content: clean_content,
          link: url
        }
      end
      
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
end

# Summarize breaking news content using AI
def summarize_breaking_news(breaking_news)
  return "No breaking news available for summarization." if breaking_news.nil? || breaking_news.empty?
  
  begin
    # Combine the latest breaking news entries for summarization
    latest_entries = breaking_news.first(5) # Limit to most recent 5 entries
    content_text = latest_entries.map { |entry| "#{entry[:timestamp]}: #{entry[:content]}" }.join('. ')
    
    return "No breaking news content available for summarization." if content_text.empty?
    
    # Skip AI summarization if no GITHUB_TOKEN is provided
    unless ENV['GITHUB_TOKEN']
      puts "No GITHUB_TOKEN provided, skipping breaking news AI summarization"
      return "AI summarization unavailable - no API token configured."
    end
    
    response = HTTParty.post(
      "https://models.inference.ai.azure.com/chat/completions",
      headers: {
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{ENV['GITHUB_TOKEN']}"
      },
      body: {
        "messages": [
          {
            "role": "system",
            "content": "Create a concise summary of the breaking news updates under 100 words. Focus on the most critical information and current developments. Identify patterns, key issues, and immediate impacts. Use urgent but clear language appropriate for breaking news. Highlight what readers need to know right now."
          },
          {
            "role": "user",
            "content": content_text[0..3072] # Limit content to fit within token limits
          }
        ],
        "model": "gpt-4o-mini",
        "temperature": 0.3, # Lower temperature for factual breaking news
        "max_tokens": 200,
        "top_p": 0.9
      }.to_json
    )
    parsed_response = sanitize_response(response.body)
    
    if parsed_response && parsed_response["choices"] && !parsed_response["choices"].empty?
      summary = parsed_response["choices"].first["message"]["content"]
      summary = summary.gsub("\n", "<br/>") # Format for HTML line breaks
      summary = summary.gsub(/(##\s*)(.*)/) { |match| "<h2>#{html_escape($2)}</h2>" } # Format headers with escaping
      summary = convert_markdown_links_to_html(summary) # Convert Markdown links to HTML
      summary = summary.gsub(/\*\*(.*?)\*\*/) { |match| "<b>#{html_escape($1)}</b>" } # Convert **text** to bold with proper escaping
      summary
    else
      "Summary generation failed - no valid response from AI service."
    end
  rescue HTTParty::Error => e
    puts "HTTP error summarizing breaking news: #{e.message}"
    "Summary unavailable due to network error."
  rescue => e
    puts "General error summarizing breaking news: #{e.message}"
    "Summary generation failed due to technical error."
  end
end

def cache_summary(summary)
  return unless summary && !summary.empty?
  
  begin
    FileUtils.mkdir_p('cache')
    File.open(CACHE_FILE, 'w') do |f|
      f.write({ timestamp: Time.now.utc.iso8601, summary: summary }.to_json)
    end
    puts "Summary cached successfully"
  rescue => e
    puts "Warning: Failed to cache summary: #{e.message}"
  end
end

def load_cached_summary
  # Skip cache if force regeneration is requested
  if ENV['FORCE_REGENERATE'] == 'true'
    puts "Force regeneration enabled, skipping cache"
    return nil
  end
  
  return unless File.exist?(CACHE_FILE)
  
  begin
    data = JSON.parse(File.read(CACHE_FILE))
    timestamp = Time.parse(data['timestamp'])
    summary = data['summary']
    
    # Check if cache is still valid (6 hours)
    if Time.now.utc - timestamp < 6 * 60 * 60
      puts "Loaded cached summary from #{timestamp}"
      summary
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

# Validate configuration and log startup info
puts "RSS Firehose starting..."
puts "Title: #{title}"
puts "Description: #{description}"
puts "RSS URLs: #{rss_urls.join(', ')}" if rss_urls.any?
puts "Backup URLs: #{rss_backup_urls.join(', ')}" if rss_backup_urls.any?
puts "GitHub Token: #{ENV['GITHUB_TOKEN'] ? 'configured' : 'not configured (AI summaries disabled)'}"
puts "Analytics UA: #{ENV['ANALYTICS_UA'] ? 'configured' : 'not configured'}"
puts ""

feeds = rss_urls.map { |url| [url, feed(url)] }.to_h.compact
breaking_news = fetch_yubanet_breaking_news
breaking_news_summary = summarize_breaking_news(breaking_news)
cached_summary = load_cached_summary

if cached_summary
  overall_summary = cached_summary
  feed_summaries = feeds.transform_values { |feed| "Cached summary used." }
  puts "Using cached summary."
else
  puts "Generating summaries for #{feeds.size} feeds..."
  feed_summaries = feeds.transform_values { |feed| summarize_news(feed) }
  overall_summary = summarize_overall_news(feeds.values)
  
  # Only cache if we actually got a useful summary
  if overall_summary && !overall_summary.include?("unavailable") && !overall_summary.include?("failed")
    cache_summary(overall_summary)
    puts "Generated and cached new summary."
  else
    puts "Generated summary but not caching due to errors."
  end
end

puts "Overall Summary: #{overall_summary}"

begin
  render_manifest
  render_html(overall_summary, feed_summaries, breaking_news, breaking_news_summary)
  puts "Successfully rendered HTML and manifest files."
rescue => e
  puts "Error during rendering process: #{e.message}"
  puts "Backtrace: #{e.backtrace.first(5).join("\n")}"
end
