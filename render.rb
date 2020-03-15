#!/usr/bin/env ruby
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
  response = HTTParty.get(url,
                          timeout: 60,
                          headers: { 'User-Agent' => 'rss-firehose' })
  RSS::Parser.parse(response.body, _do_validate = false)
end

render_manifest
render_html
