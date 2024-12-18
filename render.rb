#!/usr/bin/env ruby
# frozen_string_literal: true

require 'erb'
require 'rss'
require 'httparty'
require 'json'

def title
  ENV['RSS_TITLE'] || 'News Firehose'
end

def rss_urls
  if ENV['RSS_URLS']
    ENV['RSS_URLS'].split(',')
  else
    File.readlines('urls.txt').map(&:chomp)
  end
end

def description
  ENV['RSS_DESCRIPTION'] || 'View the latest news.'
end

def analytics_ua
  ENV['ANALYTICS_UA']
end

def render_html(news_summary)
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
    if rss_content.nil? || rss_content.items.empty?
      puts "Feed from '#{url}' returned no items, retrying once..."
      response = HTTParty.get(url, timeout: 60, headers: { 'User-Agent' => 'rss-firehose feed aggregator' })
      rss_content = RSS::Parser.parse(response.body, false) if response.code == 200
    end
    # If still empty or nil, set the rss_content to a single item stating the feed is offline
    if rss_content.nil? || rss_content.items.empty?
      puts "Feed from '#{url}' failed after retry. Response Code: #{response.code}"
      puts "Response Body: #{response.body[0..500]}" # Log first 500 characters of the response body for debugging
      rss_content = RSS::Rss.new('2.0')
      rss_content.channel = RSS::Rss::Channel.new
      rss_content.channel.title = "Feed currently offline: #{url}"
      rss_content.channel.link = url
      rss_content.channel.description = "The feed from '#{url}' is currently offline or returned no items."
    end

    rss_content
  rescue HTTParty::Error, RSS::Error => e
    puts "Error fetching or parsing feed from '#{url}': #{e.class} - #{e.message}"
    return "Feed currently offline: #{url}"
  rescue => e
    puts "General error with feed '#{url}': #{e.message}"
    nil
  end
end

def sanitize_response(response_body)
  JSON.parse(response_body)
rescue JSON::ParserError => e
  puts "JSON parsing error: #{e.message}"
  nil
end

def summarize_news(feeds)
  begin
    news_content = feeds.map do |feed|
      feed.items.map { |item| "#{item.title} (#{item.link})" }.join('. ')
    end.join('. ')
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
            "content": "Provide a concise summary in the style of a news brief, focusing on the most important details and key context for the reader. Include inline links to the relevant articles within the summary"
          },
          {
            "role": "user",
            "content": news_content[0..3500] # Adjust to fit within token limits
          }
        ],
        "model": "gpt-4o",
        "temperature": 1,
        "max_tokens": 4096,
        "top_p": 1
      }.to_json
    )
    parsed_response = sanitize_response(response.body)
    
    # Log the entire response for debugging
    puts "API Response: #{response.body}"
    
    if parsed_response && parsed_response["choices"] && !parsed_response["choices"].empty?
      summary = parsed_response["choices"].first["message"]["content"]
      summary = summary.gsub("\n", "<br/>") # Format for HTML line breaks
      summary = summary.gsub(/(##\s*)(.*)/, '<h2>\2</h2>') # Format headers
    else
      summary = "No summary available."
    end
    summary
  rescue HTTParty::Error => e
    puts "HTTP error summarizing news: #{e.message}"
    nil
  rescue => e
    puts "General error summarizing news: #{e.message}"
    nil
  end
end

feeds = rss_urls.map { |url| feed(url) }.compact
news_summary = summarize_news(feeds)
puts "News Summary: #{news_summary}"

begin
  render_manifest
  render_html(news_summary)
rescue => e
  puts "Error during rendering process: #{e.message}"
end
