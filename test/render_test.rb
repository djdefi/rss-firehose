require 'minitest/autorun'
require 'tempfile'

require_relative '../render'

# Test seam: replace the network layer with an in-memory fixture table so tests
# are fully offline and can assert exactly how many HTTP requests happen.
HTTP_CALLS = []
FIXTURES = {}

def http_get(url)
  HTTP_CALLS << url
  FIXTURES[url]
end

RSS2_FIXTURE = <<~XML
  <?xml version="1.0"?>
  <rss version="2.0"><channel><title>Example</title><link>http://ex.com</link><description>d</description>
    <item><title>Plain &amp; Simple &lt;ok&gt;</title><link>http://ex.com/1</link></item>
    <item><title>Danger &lt;script&gt;alert(1)&lt;/script&gt;</title><link>http://ex.com/2?a=1&amp;b=2</link></item>
  </channel></rss>
XML

ATOM_FIXTURE = <<~XML
  <?xml version="1.0" encoding="utf-8"?>
  <feed xmlns="http://www.w3.org/2005/Atom"><title>Atom Example</title>
    <entry><title>Atom Item</title><link href="http://ex.com/a1"/></entry>
  </feed>
XML

class RenderTest < Minitest::Test
  def setup
    HTTP_CALLS.clear
    FIXTURES.clear
    %w[RSS_URLS RSS_TITLE RSS_DESCRIPTION ANALYTICS_UA].each { |k| ENV.delete(k) }
  end

  def teardown
    %w[RSS_URLS RSS_TITLE RSS_DESCRIPTION ANALYTICS_UA].each { |k| ENV.delete(k) }
  end

  # --- configuration helpers ------------------------------------------------

  def test_rss_urls_trims_and_skips_blanks_and_comments
    ENV['RSS_URLS'] = 'http://a.com/feed/, ,# a comment,http://b.com/feed/'
    assert_equal ['http://a.com/feed/', 'http://b.com/feed/'], rss_urls
  end

  def test_site_url_returns_scheme_and_host
    assert_equal 'http://a.com', site_url('http://a.com/feed/')
    assert_equal 'https://a.com', site_url('https://a.com/feed')
    assert_equal 'https://a.com', site_url('https://a.com/rss.xml?x=1&y=2')
    assert_equal 'https://www.site.gov', site_url('https://www.site.gov/RSSFeed.aspx?ModID=1')
  end

  def test_title_and_description_env_overrides
    assert_equal 'News Firehose', title
    ENV['RSS_TITLE'] = 'My News'
    assert_equal 'My News', title
    ENV['RSS_DESCRIPTION'] = 'Custom'
    assert_equal 'Custom', description
  end

  # --- fetching / parsing ---------------------------------------------------

  def test_rss2_feed_is_parsed_and_normalized
    ENV['RSS_URLS'] = 'http://ex.com/feed/'
    FIXTURES['http://ex.com/feed/'] = RSS2_FIXTURE
    feed = feeds.first
    assert_nil feed[:error]
    assert_equal 'http://ex.com', feed[:site]
    assert_equal 2, feed[:items].count
    assert_equal 'Plain & Simple <ok>', feed[:items].first[:title]
    assert_equal 'http://ex.com/1', feed[:items].first[:link]
  end

  def test_atom_feed_title_and_link_are_normalized
    ENV['RSS_URLS'] = 'http://ex.com/atom'
    FIXTURES['http://ex.com/atom'] = ATOM_FIXTURE
    item = feeds.first[:items].first
    assert_equal 'Atom Item', item[:title]
    assert_equal 'http://ex.com/a1', item[:link]
  end

  def test_each_feed_is_fetched_exactly_once_even_when_referenced_repeatedly
    ENV['RSS_URLS'] = 'http://a.com/feed/,http://b.com/feed/'
    FIXTURES['http://a.com/feed/'] = RSS2_FIXTURE
    FIXTURES['http://b.com/feed/'] = ATOM_FIXTURE
    feeds
    feeds # second reference must hit the memoized data, not the network
    assert_equal ['http://a.com/feed/', 'http://b.com/feed/'], HTTP_CALLS
  end

  def test_unreachable_feed_does_not_raise
    ENV['RSS_URLS'] = 'http://down.com/feed/'
    FIXTURES['http://down.com/feed/'] = nil # simulate network failure
    feed = feeds.first
    assert_equal 'unavailable', feed[:error]
    assert_empty feed[:items]
  end

  def test_garbage_body_is_treated_as_unavailable
    ENV['RSS_URLS'] = 'http://junk.com/feed/'
    FIXTURES['http://junk.com/feed/'] = '<html><body>not a feed</body></html>'
    feed = feeds.first
    assert_equal 'unavailable', feed[:error]
    assert_empty feed[:items]
  end

  # --- rendering / escaping -------------------------------------------------

  def test_rendered_html_escapes_untrusted_feed_content
    ENV['RSS_URLS'] = 'http://ex.com/feed/'
    FIXTURES['http://ex.com/feed/'] = RSS2_FIXTURE
    html = render_index_to_string
    refute_includes html, '<script>alert(1)</script>'
    assert_includes html, '&lt;script&gt;alert(1)&lt;/script&gt;'
    assert_includes html, 'http://ex.com/2?a=1&amp;b=2'
  end

  def test_rendered_html_marks_unavailable_feeds
    ENV['RSS_URLS'] = 'http://down.com/feed/'
    FIXTURES['http://down.com/feed/'] = nil
    assert_includes render_index_to_string, '(unavailable)'
  end

  private

  def render_index_to_string
    Tempfile.create(['index', '.html']) do |file|
      render_template('templates/index.html.erb', file.path)
      File.read(file.path)
    end
  end
end
