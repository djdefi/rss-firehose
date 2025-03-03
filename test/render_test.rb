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
    placeholder_message = "<a href='http://example.com/invalid_feed'>http://example.com/invalid_feed - 0 items:</a>"
    # Run render.rb with the invalid URL to simulate the parsing error
    `RSS_URLS=#{invalid_feed_url} ruby render.rb`
    output = File.read('public/index.html')
    assert_includes output, placeholder_message, "The placeholder message for a parsing error is not correctly inserted."
  end

  def test_backup_feed_functionality
    # Simulate a primary feed failure and verify backup feed is used
    primary_feed_url = "http://example.com/primary_feed"
    backup_feed_url = "http://example.com/backup_feed"
    placeholder_message = "<a href='http://example.com/backup_feed'>http://example.com/backup_feed - 0 items:</a>"
    # Run render.rb with the primary feed URL and backup feed URL
    `RSS_URLS=#{primary_feed_url} RSS_BACKUP_URLS=#{backup_feed_url} ruby render.rb`
    output = File.read('public/index.html')
    assert_includes output, placeholder_message, "The backup feed is not correctly used when the primary feed fails."
  end

  # Additional tests to verify specific content or structure can be added here
end
