require 'rss'
require 'httparty'

# Read list of URLs from file
File.foreach('urls.txt') do |url|
    # Remove extra characters and URI encode
  url.chomp!
  url = URI.encode(url)

  # Get the feeds and parse them. We don't validate because some feeds are
  # malformed slightly and break the parser.
  response = HTTParty.get(url, timeout: 60)
  feed = RSS::Parser.parse(response.body, do_validate = false)

  # Feed headers HTML
  puts '<hr>'
  puts "<a href='#{url}'>#{url} - #{feed.items.count} items:</a>"
  puts '<ul>'

  # Items listing in HTML
  feed.items.each do |item|
    puts "  <li><a href='#{item.link}'>#{item.title}</a></li>"
  end
end
puts '</ul>'
