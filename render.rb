#!/usr/bin/env ruby
# frozen_string_literal: true

require 'erb'
require 'rss'
require 'httparty'

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

def render_html
  begin
    html = File.open('templates/index.html.erb').read
    template = ERB.new(html, trim_mode: '-')
    File.open('public/index.html', 'w') do |f|
      f.puts template.result
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
      f.puts template.result
    end
  rescue => e
    puts "Warning: Failed to manifest JSON. Error: #{e.message}"
  end
end

# Get the feeds and parse them. We don't validate because some feeds are
# malformed slightly and break the parser.
def feed(url)
  begin
    response = HTTParty.get(url, timeout: 60, headers: { 'User-Agent' => 'rss-firehose' })
    return RSS::Parser.parse(response.body, do_validate = false)
  rescue => e
    puts "Warning: Could not fetch or parse the feed from '#{url}'. Error: #{e.message}"
    return nil
  end
end

render_manifest
render_html
