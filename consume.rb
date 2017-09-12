require 'rss'
require 'httparty'

File.foreach('urls.txt') do |url|
  begin
    url.chomp!
    url = URI.encode(url)
    response = HTTParty.get(url, timeout: 60)
    feed = RSS::Parser.parse(response.body, do_validate = false)
    puts '<hr>'
    puts "<a href='#{url}'>#{url} - #{feed.items.count} items:</a>"
    puts '<ul>'

    feed.items.each do |item|
      puts "<li><a href='#{item.link}'>#{item.title}</a></li>"
    end
  rescue StandardError => e
    puts
    puts "ERROR: Had trouble parsing #{url} !"
    puts e.message
    puts e.backtrace.inspect
  end
  puts '</ul>'
end
