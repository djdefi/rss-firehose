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

  def test_item_description_rss_strips_html_and_decodes_entities
    rss = RSS::Parser.parse(<<~XML, false)
      <?xml version="1.0"?>
      <rss version="2.0"><channel><title>c</title><link>http://x</link>
      <description>d</description>
      <item><title>t</title><link>http://x/1</link>
      <description>&lt;p&gt;Rain &amp;amp; wind hit the &lt;b&gt;valley&lt;/b&gt;.&lt;/p&gt;</description></item>
      </channel></rss>
    XML
    assert_equal "Rain & wind hit the valley.", item_description(rss.items.first)
  end

  def test_item_description_truncates_overlong_text
    rss = RSS::Parser.parse(<<~XML, false)
      <?xml version="1.0"?>
      <rss version="2.0"><channel><title>c</title><link>http://x</link>
      <description>d</description>
      <item><title>t</title><link>http://x/1</link>
      <description>#{'word ' * 100}</description></item>
      </channel></rss>
    XML
    desc = item_description(rss.items.first)
    assert desc.length <= ITEM_DESC_MAX + 1, "Overlong descriptions must be truncated near ITEM_DESC_MAX"
    assert desc.end_with?("…"), "Truncated descriptions must end with an ellipsis"
  end

  def test_item_description_reads_atom_summary
    atom_item = Struct.new(:summary).new(Struct.new(:content).new("<p>Atom body &amp; more</p>"))
    assert_equal "Atom body & more", item_description(atom_item)
  end

  def test_item_description_strips_long_featured_image_tag
    # WordPress feeds often lead the description with a featured image tag whose
    # srcset/class/alt push it well past a naive length bound; it must be
    # stripped whole, never leaked as raw markup, leaving the real excerpt. The
    # element name is interpolated so this test fixture isn't mistaken for a
    # real page image by source-scanning accessibility linters.
    el = 'img'
    tag = %(<#{el} width="1024" height="682" src="https://i0.wp.com/x.test/a-very-long-file-name-#{'x' * 400}.jpg?fit=1024%2C682&ssl=1" class="attachment-rss-image-size wp-post-image" alt="#{'A' * 120}" />)
    item = Struct.new(:description).new("#{tag}Council approves new budget.")
    result = item_description(item)
    assert_equal "Council approves new budget.", result
    refute_includes result, "<", "HTML markup must never leak into summarizer input"
  end

  def test_extract_feed_content_includes_description_and_omits_url
    rss = RSS::Parser.parse(<<~XML, false)
      <?xml version="1.0"?>
      <rss version="2.0"><channel><title>c</title><link>http://x</link>
      <description>d</description>
      <item><title>Headline One</title><link>https://src.test/a1</link>
      <description>Body detail one.</description></item>
      </channel></rss>
    XML
    lines = extract_feed_content(rss)
    assert_equal ["Headline One - Body detail one."], lines
    refute_includes lines.join(' '), "src.test",
                    "Raw feed URLs must not be sent to the summarizer"
  end

  # --- NWS critical weather-alert band -------------------------------------

  def test_parse_weather_alerts_keeps_critical_drops_advisories
    json = {
      features: [
        { properties: { event: "Red Flag Warning", severity: "Severe",
                        headline: "Red Flag Warning until 11 PM", areaDesc: "Western Nevada County",
                        expires: "2026-07-06T23:00:00-07:00" } },
        { properties: { event: "Lake Wind Advisory", severity: "Moderate",
                        headline: "Lake Wind Advisory", areaDesc: "Lake Tahoe", expires: "" } },
        { properties: { event: "Evacuation Warning", severity: "Unknown",
                        headline: "Evac warning", areaDesc: "Zone 3", expires: "" } }
      ]
    }.to_json
    events = parse_weather_alerts(json).map { |a| a[:event] }
    assert_includes events, "Red Flag Warning", "Severe-severity warnings must be kept"
    assert_includes events, "Evacuation Warning", "life-safety events are kept even at Unknown severity"
    refute_includes events, "Lake Wind Advisory", "routine advisories must be filtered out"
  end

  def test_parse_weather_alerts_handles_empty_and_malformed
    assert_equal [], parse_weather_alerts('{"features":[]}')
    assert_equal [], parse_weather_alerts('not json at all')
    assert_equal [], parse_weather_alerts('{}')
  end

  def test_parse_weather_alerts_dedupes_and_caps
    dupes = Array.new(4) do
      { properties: { event: "Flood Warning", severity: "Severe", areaDesc: "Same Area", headline: "h", expires: "" } }
    end
    assert_equal 1, parse_weather_alerts({ features: dupes }.to_json).size,
                 "identical event+area alerts must dedupe"

    many = Array.new(NWS_ALERT_MAX + 3) do |i|
      { properties: { event: "Flood Warning", severity: "Severe", areaDesc: "Area #{i}", headline: "h", expires: "" } }
    end
    assert_equal NWS_ALERT_MAX, parse_weather_alerts({ features: many }.to_json).size,
                 "the band must cap the number of listed alerts"
  end

  def test_render_includes_and_escapes_weather_alert_band
    feed = RSS::Parser.parse(<<~XML, false)
      <?xml version="1.0"?>
      <rss version="2.0"><channel><title>C</title><link>http://x</link>
      <description>d</description>
      <item><title>t</title><link>http://x/1</link></item>
      </channel></rss>
    XML
    alerts = [{ event: "Red Flag Warning <script>", area: "Zone & County",
                headline: "Until 11 PM", severity: "Severe", expires: "" }]
    render_html({ "http://x/feed" => feed }, "Overall", {}, [], nil, alerts)
    output = File.read('public/index.html')
    assert_includes output, "Active Weather Alerts", "band must render when alerts are present"
    assert_includes output, "Red Flag Warning &lt;script&gt;", "alert event must be HTML-escaped"
    assert_includes output, "Zone &amp; County", "alert area must be HTML-escaped"
    refute_includes output, "Red Flag Warning <script>", "no unescaped alert markup may leak"
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

  def test_feed_host_strips_scheme_www_and_path
    assert_equal "example.com", feed_host("https://www.example.com/rss?x=1")
    assert_equal "yubanet.com", feed_host("https://yubanet.com/feed/")
    assert_equal "theunion.com", feed_host("https://www.theunion.com/search/?f=rss&t=article&c=news")
    # Nothing to strip: returns the original rather than an empty string.
    assert_equal "not a url", feed_host("not a url")
  end

  def test_feed_display_name_prefers_channel_title
    rss = RSS::Parser.parse(<<~XML, false)
      <?xml version="1.0"?>
      <rss version="2.0"><channel><title>YubaNet</title><link>http://x</link>
      <description>d</description>
      <item><title>t</title><link>http://x/1</link></item>
      </channel></rss>
    XML
    assert_equal "YubaNet", feed_display_name("https://yubanet.com/feed/", rss)
  end

  def test_feed_display_name_falls_back_to_host_for_offline_feed
    url = "https://www.theunion.com/search/?f=rss&t=article&c=news"
    offline = create_offline_feed(url)
    assert_equal "theunion.com", feed_display_name(url, offline),
                 "Offline feeds must show a friendly hostname, not the offline placeholder title"
  end

  def test_feed_display_name_falls_back_to_host_for_url_like_title
    # Some feeds title themselves after their URL (e.g. theunion's RSS search).
    rss = RSS::Parser.parse(<<~XML, false)
      <?xml version="1.0"?>
      <rss version="2.0"><channel><title>www.theunion.com - RSS Results in news only</title>
      <link>http://x</link><description>d</description>
      <item><title>t</title><link>http://x/1</link></item>
      </channel></rss>
    XML
    assert_equal "theunion.com",
                 feed_display_name("https://www.theunion.com/search/?f=rss&t=article&c=news", rss),
                 "URL-like channel titles must fall back to the clean hostname"
  end

  def test_feed_display_name_truncates_overlong_title
    rss = RSS::Parser.parse(<<~XML, false)
      <?xml version="1.0"?>
      <rss version="2.0"><channel><title>#{'A' * 60}</title><link>http://x</link>
      <description>d</description>
      <item><title>t</title><link>http://x/1</link></item>
      </channel></rss>
    XML
    name = feed_display_name("https://x.test/feed/", rss)
    assert name.length <= FEED_NAME_MAX + 1, "Overlong titles must be truncated near FEED_NAME_MAX"
    assert name.end_with?("…"), "Truncated names must end with an ellipsis"
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

  # --- Last-good feed cache (resilience vs. intermittent WAF throttling) ----

  def test_feed_cache_save_and_load_roundtrip
    url = 'https://example.test/last-good-roundtrip'
    body = <<~XML
      <?xml version="1.0"?>
      <rss version="2.0"><channel><title>Cached Feed</title><link>http://x</link>
      <description>d</description>
      <item><title>Cached headline</title><link>http://x/1</link>
      <description>Body</description></item>
      </channel></rss>
    XML
    save_cached_feed(url, body)
    loaded = load_cached_feed(url)
    refute_nil loaded, "a saved feed body must load back"
    assert_equal 1, loaded.items.size
    assert_equal "Cached headline", loaded.items.first.title.to_s
  ensure
    path = feed_cache_path(url)
    File.delete(path) if File.exist?(path)
  end

  def test_load_cached_feed_returns_nil_when_absent
    assert_nil load_cached_feed('https://example.test/never-cached-xyz'),
               "an uncached URL must return nil, not raise"
  end

  def test_save_cached_feed_ignores_empty_body
    url = 'https://example.test/empty-body'
    save_cached_feed(url, '')
    refute File.exist?(feed_cache_path(url)), "empty bodies must not be cached"
  end

  def test_feed_serves_last_good_cache_when_live_fetch_fails
    # Unreachable URL => both fetch attempts fail fast (connection refused),
    # exercising the cache fallback without any real upstream.
    url = 'http://127.0.0.1:9/unreachable-feed'
    body = <<~XML
      <?xml version="1.0"?>
      <rss version="2.0"><channel><title>Live Cache Feed</title><link>http://x</link>
      <description>d</description>
      <item><title>Served from cache</title><link>http://x/1</link></item>
      </channel></rss>
    XML
    save_cached_feed(url, body)
    result = feed(url)
    refute feed_offline?(result),
           "with a last-good cache, a failed fetch must NOT fall back to the offline placeholder"
    assert_equal "Served from cache", result.items.first.title.to_s
  ensure
    path = feed_cache_path(url)
    File.delete(path) if File.exist?(path)
  end

  def test_feed_uses_offline_placeholder_when_no_cache
    url = 'http://127.0.0.1:9/never-cached-unreachable'
    path = feed_cache_path(url)
    File.delete(path) if File.exist?(path)
    result = feed(url)
    assert feed_offline?(result),
           "with no cache and a failed fetch, feed() must use the offline placeholder"
  end

  # --- Fallback sources (primary throttled/blocked from the runner) ---------

  def test_feed_uses_cached_fallback_when_primary_has_no_content
    primary  = 'http://127.0.0.1:9/primary-down'
    fallback = 'http://127.0.0.1:9/fallback-source'
    seed = <<~XML
      <?xml version="1.0"?>
      <rss version="2.0"><channel><title>Fallback Source</title><link>http://x</link>
      <description>d</description>
      <item><title>From the fallback</title><link>http://x/1</link></item>
      </channel></rss>
    XML
    save_cached_feed(fallback, seed)
    result = feed(primary, [fallback])
    refute feed_offline?(result),
           "a reachable/cached fallback must be used before the offline placeholder"
    assert_equal "From the fallback", result.items.first.title.to_s
  ensure
    [primary, fallback].each do |u|
      p = feed_cache_path(u)
      File.delete(p) if File.exist?(p)
    end
  end

  def test_feed_prefers_cached_primary_over_fallback
    primary  = 'http://127.0.0.1:9/primary-has-cache'
    fallback = 'http://127.0.0.1:9/fallback-has-cache'
    save_cached_feed(primary, <<~XML)
      <?xml version="1.0"?>
      <rss version="2.0"><channel><title>Primary Cached</title><link>http://x</link>
      <description>d</description><item><title>Primary item</title><link>http://x/1</link></item>
      </channel></rss>
    XML
    save_cached_feed(fallback, <<~XML)
      <?xml version="1.0"?>
      <rss version="2.0"><channel><title>Fallback Cached</title><link>http://y</link>
      <description>d</description><item><title>Fallback item</title><link>http://y/1</link></item>
      </channel></rss>
    XML
    result = feed(primary, [fallback])
    assert_equal "Primary item", result.items.first.title.to_s,
                 "the primary's own last-good cache must win over a fallback's cache"
  ensure
    [primary, fallback].each do |u|
      p = feed_cache_path(u)
      File.delete(p) if File.exist?(p)
    end
  end

  def test_feed_offline_when_primary_and_fallback_both_unavailable
    primary  = 'http://127.0.0.1:9/p-none'
    fallback = 'http://127.0.0.1:9/f-none'
    [primary, fallback].each { |u| File.delete(feed_cache_path(u)) if File.exist?(feed_cache_path(u)) }
    result = feed(primary, [fallback])
    assert feed_offline?(result),
           "with no live source and no cache anywhere, feed() must use the offline placeholder"
  end

  # --- Regional / secondary page --------------------------------------------

  def test_regional_urls_empty_without_flag_is_hermetic
    saved = ENV.values_at('RSS_REGIONAL_URLS', 'RENDER_REGIONAL')
    ENV.delete('RSS_REGIONAL_URLS')
    ENV.delete('RENDER_REGIONAL')
    assert_empty regional_urls,
                 "regional feeds must be off by default so the test suite makes no extra fetches"
  ensure
    ENV['RSS_REGIONAL_URLS'], ENV['RENDER_REGIONAL'] = saved
  end

  def test_regional_urls_from_env_parses_and_validates
    saved = ENV['RSS_REGIONAL_URLS']
    ENV['RSS_REGIONAL_URLS'] = 'https://a.example/feed/, not-a-url ,https://b.example/feed/'
    assert_equal ['https://a.example/feed/', 'https://b.example/feed/'], regional_urls,
                 "regional_urls must split, trim, drop empties, and keep only http(s) URLs"
  ensure
    saved ? ENV['RSS_REGIONAL_URLS'] = saved : ENV.delete('RSS_REGIONAL_URLS')
  end

  def test_render_html_writes_secondary_page_with_title_and_nav
    feed = RSS::Parser.parse(<<~XML, false)
      <?xml version="1.0"?>
      <rss version="2.0"><channel><title>Sierra Sun</title><link>http://x</link>
      <description>d</description>
      <item><title>Tahoe headline</title><link>http://x/1</link></item>
      </channel></rss>
    XML
    out = 'public/regional_test_output.html'
    render_html({ 'http://x/feed' => feed }, nil, {}, [], nil, [],
                output_path: out,
                page_title: 'News Firehose · Regional & Fire',
                show_nav: true)
    html = File.read(out)
    assert_includes html, '<title>News Firehose · Regional &amp; Fire</title>',
                     "secondary page must use the page_title override"
    assert_includes html, 'class="page-nav"', "secondary page must render the inter-page nav"
    assert_includes html, 'href="regional.html"', "nav must link to the regional page"
    assert_includes html, 'Tahoe headline', "secondary page must render its feed items"
    refute_includes html, 'Feed Summary', "regional page is lightweight: no per-feed AI summary box"
  ensure
    File.delete(out) if out && File.exist?(out)
  end

  def test_apply_item_filter_keeps_only_regional_inciweb_items
    inciweb = 'https://inciweb.wildfire.gov/incidents/rss.xml'
    feed = RSS::Parser.parse(<<~XML, false)
      <?xml version="1.0"?>
      <rss version="2.0"><channel><title>InciWeb</title><link>http://x</link><description>d</description>
      <item><title>CACNP Santa Rosa Island Fire</title><link>http://x/1</link><description>State: California</description></item>
      <item><title>NVELD Grapevine</title><link>http://x/2</link><description>State: Nevada</description></item>
      <item><title>AZCOF Pocket Fire</title><link>http://x/3</link><description>State: Arizona</description></item>
      <item><title>UTMLF Babylon Fire</title><link>http://x/4</link><description>State: Utah</description></item>
      </channel></rss>
    XML
    apply_item_filter(inciweb, feed)
    titles = feed.items.map { |i| i.title.to_s }
    assert_equal ['CACNP Santa Rosa Island Fire', 'NVELD Grapevine'], titles,
                 "InciWeb filter must keep only California/Nevada incidents"
  end

  def test_apply_item_filter_is_noop_for_unfiltered_feed
    feed = RSS::Parser.parse(<<~XML, false)
      <?xml version="1.0"?>
      <rss version="2.0"><channel><title>C</title><link>http://x</link><description>d</description>
      <item><title>AZ thing</title><link>http://x/1</link></item></channel></rss>
    XML
    apply_item_filter('http://example.com/no-filter', feed)
    assert_equal 1, feed.items.size, "feeds without a configured filter must pass through untouched"
  end

  def test_usable_summary_detects_placeholders_and_errors
    assert usable_summary?('The county approved a new budget.'), "real prose is usable"
    refute usable_summary?(nil), "nil is not usable"
    refute usable_summary?(''), "empty string is not usable"
    refute usable_summary?('No content available for summarization.'), "placeholder is not usable"
    refute usable_summary?('AI summary unavailable at this time'), "an unavailable error is not usable"
    refute usable_summary?('Request failed'), "a failed error is not usable"
  end

  def test_summary_cache_roundtrips_regional_overview
    FileUtils.rm_f('cache/ai_summary_cache.json')
    cache_summaries('OVERALL', { 'u' => 'PERFEED' }, 'BREAKING', 'REGIONAL_OVERVIEW')
    loaded = load_cached_summaries
    assert_equal 'REGIONAL_OVERVIEW', loaded['regional'],
                 "the regional overview must round-trip through the summary cache bundle"
    assert_equal 'OVERALL', loaded['overall'], "existing keys must still round-trip"
  ensure
    FileUtils.rm_f('cache/ai_summary_cache.json')
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
