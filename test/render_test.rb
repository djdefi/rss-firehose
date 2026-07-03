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
    assert_includes output, "Loaded cached summary", "Cache should be loaded when FORCE_REGENERATE is false"
    
    puts "✓ Force regeneration feature works correctly"
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
end
