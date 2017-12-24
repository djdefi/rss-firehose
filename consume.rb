#!/usr/bin/env ruby
require 'rss'
require 'httparty'
require 'sinatra'

def grabrss
  File.open('public/index.html', 'w') do |fo|
    # Read list of URLs from file
    File.foreach('urls.txt') do |url|
      # Remove extra characters and URI encode
      url.chomp!
      url = URI.encode(url)

      # Get the feeds and parse them. We don't validate because some feeds are
      # malformed slightly and break the parser.
      response = HTTParty.get(url, timeout: 60)
      feed = RSS::Parser.parse(response.body, _do_validate = false)

      # Feed headers HTML
      fo.puts '<hr>'
      fo.puts "<a href='#{url}'>#{url} - #{feed.items.count} items:</a>"
      fo.puts '<ul>'

      # Items listing in HTML
      feed.items.each do |item|
        fo.puts "  <li><a href='#{item.link}'>#{item.title}</a></li>"
      end
      fo.puts '</ul>'
    end
  end
end

get '/' do
  grabrss
  html :index
end

def html(view)
  File.read(File.join('public', "#{view}.html"))
end
