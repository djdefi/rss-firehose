#!/usr/bin/env ruby
require 'erb'
require 'rss'
require 'httparty'

def render
  html = File.open('templates/index.html.erb').read do
    template = ERB.new(html, nil, '-')
    template.result
    File.open('public/index.html', 'w') do |fo|
      fo.puts template.result
    end
  end
end

def rss_urls
  File.readlines('urls.txt').map(&:chomp)
end

# Get the feeds and parse them. We don't validate because some feeds are
# malformed slightly and break the parser.
def feed(url)
  response = HTTParty.get(url, timeout: 60)
  RSS::Parser.parse(response.body, _do_validate = false)
end

def title
  'News Firehose'
end

render
