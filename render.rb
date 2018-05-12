#!/usr/bin/env ruby
require 'erb'
require 'rss'
require 'httparty'

def title
  if ENV['RSS_TITLE']
    ENV['RSS_TITLE']
  else
    'News Firehose'
  end
end

def rss_urls
  if ENV['RSS_URLS']
    ENV['RSS_URLS'].split(',')
  else
    File.readlines('urls.txt').map(&:chomp)
  end
end

def description
  if ENV['RSS_DESCRIPTION']
    ENV['RSS_DESCRIPTION']
  else
    'View the latest news.'
  end
end

def analytics_ua
  ENV['ANALYTICS_UA']
end

def render_html
  html = File.open('templates/index.html.erb').read
  template = ERB.new(html, nil, '-')
  template.result
  File.open('public/index.html', 'w') do |fo|
    fo.puts template.result
  end
end

def render_manifest
  json = File.open('templates/manifest.json.erb').read
  template = ERB.new(json, nil, '-')
  template.result
  File.open('public/manifest.json', 'w') do |fo|
    fo.puts template.result
  end
end

# Get the feeds and parse them. We don't validate because some feeds are
# malformed slightly and break the parser.
def feed(url)
  response = HTTParty.get(url, timeout: 60)
  RSS::Parser.parse(response.body, _do_validate = false)
end

render_manifest
render_html
