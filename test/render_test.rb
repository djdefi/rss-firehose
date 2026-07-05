require 'minitest/autorun'
require_relative '../render.rb'

class RenderTest < Minitest::Test
  def setup
    # Setup code to run render.rb to create public/index.html file then verify its content
    @render_stdout = `ruby render.rb 2>&1`
    @output = File.read('public/index.html')
    @expected_output_structure = "<title>News Firehose</title>"
    # Breaking-news assertions depend on live YubaNet content; capture how many
    # entries were scraped so those tests can skip (not fail) when the live
    # source is momentarily empty or unreachable.
    @breaking_news_count = @render_stdout[/Fetched (\d+) breaking news entries/, 1].to_i
  end

  def test_render_output_structure
    assert_includes @output, @expected_output_structure, "The output structure of render.rb does not match the expected HTML structure."
  end

  def test_placeholder_message_for_parsing_error
    # Simulate a parsing error by providing an invalid URL
    invalid_feed_url = "http://example.com/invalid_feed"
    # The template creates a feed item showing it's offline
    placeholder_message = "Feed offline: http://example.com/invalid_feed"
    # Run render.rb with the invalid URL to simulate the parsing error
    `RSS_URLS=#{invalid_feed_url} ruby render.rb`
    output = File.read('public/index.html')
    assert_includes output, placeholder_message, "The placeholder message for a parsing error is not correctly inserted."
  end

  def test_backup_feed_functionality
    # Simulate a primary feed failure and verify the primary feed shows as offline
    primary_feed_url = "http://example.com/primary_feed"
    backup_feed_url = "http://example.com/backup_feed"
    # Since we changed the backup logic, we expect to see the primary feed marked as offline
    placeholder_message = "Feed offline: http://example.com/primary_feed"
    # Run render.rb with the primary feed URL and backup feed URL
    `RSS_URLS=#{primary_feed_url} RSS_BACKUP_URLS=#{backup_feed_url} ruby render.rb`
    output = File.read('public/index.html')
    assert_includes output, placeholder_message, "The primary feed is not correctly shown as offline when it fails."
  end

  def test_empty_urls_fallback_to_backup
    # Test that when no RSS_URLS are provided, backup feeds are used
    backup_feed_url = "http://example.com/backup_feed"
    # Run render.rb with empty RSS_URLS and a backup feed URL
    `RSS_URLS="" RSS_BACKUP_URLS=#{backup_feed_url} ruby render.rb`
    output = File.read('public/index.html')
    placeholder_message = "Feed offline: http://example.com/backup_feed"
    assert_includes output, placeholder_message, "Backup feeds are not used when primary URLs are empty."
  end

  # Additional tests to verify specific content or structure can be added here
  
  def test_breaking_news_section_exists
    skip 'Live YubaNet returned no breaking-news entries' if @breaking_news_count.zero?
    # Test that the breaking news section is present in the output
    assert_includes @output, "Breaking News - YubaNet Live Updates", "Breaking news section should be present in the output"
    assert_includes @output, "yubanet.com/featured/now", "Breaking news should link to YubaNet featured/now page"
  end

  def test_breaking_news_function_exists
    # Load the render.rb file to get access to the functions
    load File.expand_path('../render.rb', __dir__)
    
    # Test that the breaking news function exists
    assert_includes Object.private_instance_methods, :fetch_yubanet_breaking_news, "fetch_yubanet_breaking_news function should exist"
    # Test that the breaking news summarization function exists
    assert_includes Object.private_instance_methods, :summarize_breaking_news, "summarize_breaking_news function should exist"
    
    puts "✓ Breaking news functionality is available"
  end

  def test_breaking_news_structure
    skip 'Live YubaNet returned no breaking-news entries' if @breaking_news_count.zero?
    # Test that the breaking news has proper structure with timestamps
    breaking_news_pattern = /<strong>[^<]+(?:AM|PM)[^<]*<\/strong>/
    assert_match breaking_news_pattern, @output, "Breaking news should contain timestamped entries"
  end

  def test_breaking_news_ai_summary_structure
    skip 'Live YubaNet returned no breaking-news entries' if @breaking_news_count.zero?
    # Test that AI summary section appears when available (even if not active due to no token)
    # The template should contain the conditional logic for AI summaries
    assert_includes @output, "Breaking News - YubaNet Live Updates", "Breaking news section should be present"
    
    # Test that the template structure supports AI summaries
    load File.expand_path('../render.rb', __dir__)
    template_path = File.expand_path('../templates/index.html.erb', __dir__)
    template_content = File.read(template_path)
    assert_includes template_content, "breaking_news_summary", "Template should support breaking news AI summaries"
    assert_includes template_content, "AI Summary", "Template should include AI Summary section"
  end
  
  def test_different_summary_functions_exist
    # Load the render.rb file to get access to the functions
    load File.expand_path('../render.rb', __dir__)
    
    # Test that both summary functions exist
    assert_includes Object.private_instance_methods, :summarize_news, "summarize_news function should exist"
    assert_includes Object.private_instance_methods, :summarize_overall_news, "summarize_overall_news function should exist"
    
    puts "✓ Both summarize_news and summarize_overall_news functions are available"
    puts "Note: Full summary variation testing requires GITHUB_TOKEN for integration validation"
  end

  def test_force_regenerate_skips_cache
    # Test that FORCE_REGENERATE environment variable skips cache
    load File.expand_path('../render.rb', __dir__)
    
    # Create a mock cache file
    FileUtils.mkdir_p('cache')
    cache_data = {
      'timestamp' => Time.now.utc.to_s,
      'summary' => 'Cached test summary'
    }.to_json
    File.write('cache/ai_summary_cache.json', cache_data)
    
    # Run with FORCE_REGENERATE=true
    output = `FORCE_REGENERATE=true ruby render.rb 2>&1`
    
    # Verify that cache skip message appears
    assert_includes output, "Force regeneration enabled, skipping cache", "Force regeneration should skip cache"
    
    # Run without FORCE_REGENERATE to verify cache is loaded normally
    output = `FORCE_REGENERATE=false ruby render.rb 2>&1`
    
    # Verify that cache is loaded
    assert_includes output, "Loaded cached summaries", "Cache should be loaded when FORCE_REGENERATE is false"
    
    puts "✓ Force regeneration feature works correctly"
  ensure
    FileUtils.rm_f('cache/ai_summary_cache.json')
  end

  def test_cache_hit_shows_real_summaries_not_placeholder
    # Regression: a cache hit used to blank every per-feed summary with the
    # literal string "Cached summary used." and never cached per-feed/breaking
    # summaries. The bundle cache must restore real summaries instead.
    load File.expand_path('../render.rb', __dir__)
    feed_url = 'http://example.com/cache-bundle'
    FileUtils.mkdir_p('cache')
    cache_data = {
      'timestamp' => Time.now.utc.iso8601,
      'summary' => 'OVERALL_CACHED_MARKER',
      'feed_summaries' => { feed_url => 'PERFEED_CACHED_MARKER' },
      'breaking_news_summary' => 'BREAKING_CACHED_MARKER'
    }.to_json
    File.write('cache/ai_summary_cache.json', cache_data)

    output = `RSS_URLS=#{feed_url} ruby render.rb 2>&1`
    html = File.read('public/index.html')

    assert_includes output, "Using cached summaries.", "A fresh cache should be a hit"
    refute_includes html, "Cached summary used.",
      "The placeholder must never leak to the rendered page"
    assert_includes html, "OVERALL_CACHED_MARKER", "Cached overall summary should render"
    assert_includes html, "PERFEED_CACHED_MARKER", "Cached per-feed summary should render"
  ensure
    FileUtils.rm_f('cache/ai_summary_cache.json')
  end

  def test_manifest_pwa_settings
    # Test that manifest.json is generated with correct PWA settings for iOS
    require 'json'
    
    # Ensure manifest exists
    assert File.exist?('public/manifest.json'), "manifest.json should be generated"
    
    # Parse and validate manifest content
    manifest = JSON.parse(File.read('public/manifest.json'))
    
    # Check display mode is "standalone" for proper iOS PWA behavior
    assert_equal "standalone", manifest["display"], 
      "Display mode should be 'standalone' to prevent opening new tabs on iOS"
    
    # Check start_url is properly set
    assert_equal "./", manifest["start_url"], 
      "start_url should be './' for proper iOS PWA behavior"
    
    # Verify essential manifest fields exist
    assert manifest.key?("name"), "Manifest should have a name"
    assert manifest.key?("short_name"), "Manifest should have a short_name"
    assert manifest.key?("icons"), "Manifest should have icons"
    assert manifest["icons"].is_a?(Array), "Icons should be an array"
    assert !manifest["icons"].empty?, "Icons array should not be empty"
    
    puts "✓ Manifest PWA settings are correctly configured for iOS"
  end

  # --- Feed-dialect normalization + XSS escaping ---------------------------

  def test_item_title_normalizes_rss_and_atom
    rss = RSS::Parser.parse(<<~XML, false)
      <?xml version="1.0"?>
      <rss version="2.0"><channel><title>c</title><link>http://x</link>
      <description>d</description>
      <item><title>Plain Title</title><link>http://x/1</link></item>
      </channel></rss>
    XML
    assert_equal "Plain Title", item_title(rss.items.first)

    atom_item = Struct.new(:title, :link).new(
      Struct.new(:content).new("Atom Title"), nil
    )
    assert_equal "Atom Title", item_title(atom_item)
  end

  def test_item_link_normalizes_rss_and_atom
    rss = RSS::Parser.parse(<<~XML, false)
      <?xml version="1.0"?>
      <rss version="2.0"><channel><title>c</title><link>http://x</link>
      <description>d</description>
      <item><title>t</title><link>http://x/1</link></item>
      </channel></rss>
    XML
    assert_equal "http://x/1", item_link(rss.items.first)

    atom_item = Struct.new(:title, :link).new(
      nil, Struct.new(:href).new("https://atom.test/1")
    )
    assert_equal "https://atom.test/1", item_link(atom_item)
  end

  def test_safe_url_allows_safe_and_blocks_dangerous_schemes
    assert_equal "https://ok.test/a", safe_url("https://ok.test/a")
    assert_equal "http://ok.test", safe_url("http://ok.test")
    assert_equal "/relative", safe_url("/relative")
    assert_equal "#anchor", safe_url("#anchor")
    assert_equal "mailto:a@b.test", safe_url("mailto:a@b.test")
    assert_equal "#", safe_url("javascript:alert(1)")
    assert_equal "#", safe_url("data:text/html;base64,PHNjcmlwdD4=")
    assert_equal "#", safe_url("vbscript:msgbox(1)")
  end

  def test_render_escapes_malicious_feed_content
    feed = RSS::Parser.parse(<<~XML, false)
      <?xml version="1.0"?>
      <rss version="2.0"><channel><title>Evil</title><link>http://evil.test</link>
      <description>d</description>
      <item><title>Danger &lt;script&gt;alert(1)&lt;/script&gt;</title><link>javascript:alert(1)</link></item>
      <item><title>Safe &amp; Sound</title><link>https://ok.test/a?b=1&amp;c=2</link></item>
      </channel></rss>
    XML
    feeds = { "http://evil.test/feed" => feed }
    render_html(feeds, "Overall summary", {}, [], nil)
    output = File.read('public/index.html')

    refute_includes output, "<script>alert(1)</script>",
      "Malicious script title must be escaped, not injected raw."
    assert_includes output, "Danger &lt;script&gt;alert(1)&lt;/script&gt;",
      "Escaped title should appear in output."
    refute_includes output, "href='javascript:alert(1)'",
      "javascript: URLs must be neutralized."
    assert_includes output, "href='#'",
      "Dangerous URL should collapse to '#'."
    assert_includes output, "Safe &amp; Sound",
      "Ampersand in title should be escaped."
  end

  # --- Bounded parallel map ------------------------------------------------

  def test_parallel_map_empty_returns_empty_hash
    assert_equal({}, parallel_map([]))
  end

  def test_parallel_map_applies_block_to_every_item
    items = (1..20).to_a
    result = parallel_map(items) { |n| n * n }
    assert_equal items.size, result.size, "Every item should produce a result"
    items.each { |n| assert_equal(n * n, result[n], "Item #{n} should be mapped") }
  end

  # --- Concurrent feed fetching -------------------------------------------

  def test_fetch_feeds_empty_returns_empty_hash
    assert_equal({}, fetch_feeds([]))
  end

  def test_fetch_feeds_preserves_order_and_fetches_all
    urls = %w[https://one.test https://two.test https://three.test https://four.test]
    original = method(:feed)
    begin
      # Stub feed() to avoid network; sleep so concurrency actually interleaves.
      Object.send(:define_method, :feed) do |url|
        sleep(0.02)
        "parsed:#{url}"
      end
      result = fetch_feeds(urls)
      assert_equal urls, result.keys, "Result should preserve input URL order"
      urls.each do |url|
        assert_equal "parsed:#{url}", result[url], "Every URL should be fetched"
      end
    ensure
      Object.send(:define_method, :feed, original.unbind)
    end
  end

  # --- Offline feeds don't leak AI refusals -------------------------------

  def test_feed_offline_detects_placeholder
    offline = create_offline_feed('http://example.com/down')
    assert feed_offline?(offline), "create_offline_feed output should be detected as offline"
  end

  def test_summarize_news_skips_offline_feed_returning_nil
    # Must short-circuit before any AI call, so this needs no network/token.
    offline = create_offline_feed('http://example.com/down')
    assert_nil summarize_news(offline),
               "Offline feeds must return nil so the template hides the summary box (no AI refusal leak)"
  end

  def test_summarize_overall_news_excludes_offline_feeds
    offline = create_offline_feed('http://example.com/down')
    result = summarize_overall_news([offline])
    assert_equal "No articles available for summarization.", result,
                 "An all-offline set has no real content and must not be sent to the AI"
  end

  def test_feed_falls_back_to_offline_when_fetch_keeps_failing
    # Stub the fetch/parse step to always fail (nil covers non-200, network
    # errors, and parse errors) and confirm feed() retries then falls back to
    # an offline placeholder instead of raising. No network is touched.
    original = method(:fetch_and_parse_feed)
    begin
      Object.send(:define_method, :fetch_and_parse_feed) { |_url| nil }
      result = feed('http://example.com/down')
      assert feed_offline?(result),
             "feed() should return an offline placeholder when every fetch attempt fails"
    ensure
      Object.send(:define_method, :fetch_and_parse_feed, original.unbind)
    end
  end

  # --- YubaNet breaking-news parser (fixture-based, no network) ------------

  YUBANET_FIXTURE = <<~HTML
    <div class="entry-content">
      <p class="wp-block-paragraph"></p>
      <p class="wp-block-paragraph"><strong>July 4, 2026 at 9:40 PM </strong>2026 Fourth of July Parade &#8211; the <a href="https://yubanet.com/regional/2026-fourth-of-july-parade-in-nevada-city/">photo gallery</a> is live.</p>
      <p class="wp-block-paragraph"><strong>July 4, 2026 at 9:30 PM</strong>Fireworks have started on the Dorsey Drive overpass.</p>
    </div>
  HTML

  def test_parse_breaking_news_extracts_wordpress_block_entries
    entries = parse_breaking_news(YUBANET_FIXTURE, 'https://yubanet.com/featured/now/')
    assert_equal 2, entries.size, "Both wp-block-paragraph entries should be extracted"
    assert_equal 'July 4, 2026 at 9:40 PM', entries[0][:timestamp]
    assert_equal 'https://yubanet.com/featured/now/', entries[0][:link]
  end

  def test_parse_breaking_news_strips_nested_tags_and_decodes_entities
    entries = parse_breaking_news(YUBANET_FIXTURE, 'u')
    content = entries[0][:content]
    assert_includes content, 'photo gallery', "Anchor text should be preserved"
    refute_includes content, '<a', "Nested anchor tag should be stripped"
    refute_includes content, 'href', "Anchor attributes should be stripped"
    assert_includes content, '–', "&#8211; should be decoded to an en-dash"
    refute_includes content, '&#8211;', "Raw HTML entity should not remain"
  end

  def test_parse_breaking_news_returns_empty_without_entries
    assert_equal [], parse_breaking_news('<p>no timestamped entries here</p>', 'u')
    assert_equal [], parse_breaking_news('', 'u')
    assert_equal [], parse_breaking_news(nil, 'u')
  end
end
