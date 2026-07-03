require 'minitest/autorun'
require 'tempfile'
require 'tmpdir'
require 'fileutils'

require_relative '../render'

# Test seam: replace the network layer (http_fetch) with an in-memory fixture
# table so tests are fully offline. FIXTURES maps a URL to a hash of:
#   body:          response body to parse (implies a 200)
#   etag:          validator; a cached request with a matching etag yields 304
#   last_modified: validator (informational here)
#   status:        force :error to simulate an unreachable feed
HTTP_CALLS = []
FIXTURES = {}

def http_fetch(url, cached = nil, *)
  HTTP_CALLS << url
  fixture = FIXTURES[url]
  return FetchResult.new(:error, nil, nil, nil) if fixture.nil? || fixture[:status] == :error

  if cached && fixture[:etag] && cached['etag'] == fixture[:etag]
    return FetchResult.new(:not_modified, nil, fixture[:etag], fixture[:last_modified])
  end

  FetchResult.new(:ok, fixture[:body], fixture[:etag], fixture[:last_modified])
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
  ENV_KEYS = %w[RSS_URLS RSS_TITLE RSS_DESCRIPTION ANALYTICS_UA RSS_CACHE RSS_CONCURRENCY].freeze

  def setup
    HTTP_CALLS.clear
    FIXTURES.clear
    @feeds = nil
    @tmpdir = Dir.mktmpdir
    @cache_file = File.join(@tmpdir, 'cache.json')
    ENV_KEYS.each { |k| ENV.delete(k) }
  end

  def teardown
    ENV_KEYS.each { |k| ENV.delete(k) }
    FileUtils.remove_entry(@tmpdir) if @tmpdir && Dir.exist?(@tmpdir)
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
    stub_feed('http://ex.com/feed/', body: RSS2_FIXTURE)
    feed = feeds.first
    assert_nil feed[:error]
    assert_equal 'http://ex.com', feed[:site]
    assert_equal 2, feed[:items].count
    assert_equal 'Plain & Simple <ok>', feed[:items].first[:title]
    assert_equal 'http://ex.com/1', feed[:items].first[:link]
  end

  def test_atom_feed_title_and_link_are_normalized
    stub_feed('http://ex.com/atom', body: ATOM_FIXTURE)
    item = feeds.first[:items].first
    assert_equal 'Atom Item', item[:title]
    assert_equal 'http://ex.com/a1', item[:link]
  end

  def test_unreachable_feed_does_not_raise
    stub_feed('http://down.com/feed/', status: :error)
    feed = feeds.first
    assert_equal 'unavailable', feed[:error]
    assert_empty feed[:items]
  end

  def test_garbage_body_is_treated_as_unavailable
    stub_feed('http://junk.com/feed/', body: '<html><body>not a feed</body></html>')
    feed = feeds.first
    assert_equal 'unavailable', feed[:error]
    assert_empty feed[:items]
  end

  # --- concurrency ----------------------------------------------------------

  def test_feeds_are_fetched_once_each_and_kept_in_order
    ENV['RSS_URLS'] = (1..5).map { |n| "http://s#{n}.com/feed/" }.join(',')
    (1..5).each { |n| stub_feed("http://s#{n}.com/feed/", body: RSS2_FIXTURE) }

    sites = feeds.map { |f| f[:site] }
    assert_equal (1..5).map { |n| "http://s#{n}.com" }, sites # input order preserved
    feeds # second reference is memoized, not refetched
    assert_equal (1..5).map { |n| "http://s#{n}.com/feed/" }, HTTP_CALLS.sort
    assert_equal 5, HTTP_CALLS.size
  end

  # --- conditional GET / caching --------------------------------------------

  def test_conditional_request_reuses_cache_on_304
    url = 'http://ex.com/feed/'
    ENV['RSS_URLS'] = url
    ENV['RSS_CACHE'] = @cache_file
    stub_feed(url, body: RSS2_FIXTURE, etag: 'v1')

    feeds # first run: 200 OK, writes cache with etag v1
    assert File.exist?(@cache_file), 'cache file should be written'

    @feeds = nil
    HTTP_CALLS.clear
    feed = feeds.first # second run: cached etag matches -> 304 -> served from cache
    assert_equal [url], HTTP_CALLS
    assert_nil feed[:error]
    assert_equal 2, feed[:items].count
  end

  def test_serves_stale_cache_when_feed_later_fails
    url = 'http://ex.com/feed/'
    ENV['RSS_URLS'] = url
    ENV['RSS_CACHE'] = @cache_file
    stub_feed(url, body: RSS2_FIXTURE, etag: 'v1')
    feeds # populate cache

    @feeds = nil
    stub_feed(url, status: :error) # feed goes down
    feed = feeds.first
    assert_nil feed[:error], 'should serve stale copy rather than mark unavailable'
    assert_equal 2, feed[:items].count
  end

  def test_no_cache_file_written_when_caching_disabled
    stub_feed('http://ex.com/feed/', body: RSS2_FIXTURE)
    feeds
    refute File.exist?(@cache_file)
  end

  # --- rendering / escaping -------------------------------------------------

  def test_rendered_html_escapes_untrusted_feed_content
    stub_feed('http://ex.com/feed/', body: RSS2_FIXTURE)
    html = render_index_to_string
    refute_includes html, '<script>alert(1)</script>'
    assert_includes html, '&lt;script&gt;alert(1)&lt;/script&gt;'
    assert_includes html, 'http://ex.com/2?a=1&amp;b=2'
  end

  def test_rendered_html_marks_unavailable_feeds
    stub_feed('http://down.com/feed/', status: :error)
    assert_includes render_index_to_string, '(unavailable)'
  end

  private

  def stub_feed(url, **attrs)
    ENV['RSS_URLS'] ||= url
    FIXTURES[url] = attrs
  end

  def render_index_to_string
    Tempfile.create(['index', '.html']) do |file|
      render_template('templates/index.html.erb', file.path)
      File.read(file.path)
    end
  end
end
