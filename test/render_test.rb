require 'minitest/autorun'
require_relative '../render.rb'

class RenderTest < Minitest::Test
  def setup
    # Setup code to run render.rb to create public/index.html file then verify its content
    `ruby render.rb`
    @output = File.read('public/index.html')
    @expected_output_structure = "<title>News Firehose</title>"
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
    # Test that the breaking news section is present in the output
    assert_includes @output, "Breaking News - YubaNet Live Updates", "Breaking news section should be present in the output"
    assert_includes @output, "yubanet.com/featured/now", "Breaking news should link to YubaNet featured/now page"
  end

  def test_breaking_news_function_exists
    # Load the render.rb file to get access to the functions
    load File.expand_path('../render.rb', __dir__)
    
    # Test that the breaking news function exists
    assert_includes Object.private_instance_methods, :fetch_yubanet_breaking_news, "fetch_yubanet_breaking_news function should exist"
    
    puts "✓ Breaking news functionality is available"
  end

  def test_breaking_news_structure
    # Test that the breaking news has proper structure with timestamps
    breaking_news_pattern = /<strong>[^<]+(?:AM|PM)[^<]*<\/strong>/
    assert_match breaking_news_pattern, @output, "Breaking news should contain timestamped entries"
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
end
