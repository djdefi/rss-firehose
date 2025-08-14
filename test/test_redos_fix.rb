#!/usr/bin/env ruby

# Test the ReDoS fix in convert_markdown_links_to_html
require 'minitest/autorun'

# Load the function from render.rb
$LOAD_PATH.unshift('/home/runner/.local/share/gem/ruby/3.2.0/lib')
require_relative '../render'

class TestReDoSFix < Minitest::Test
  def test_normal_markdown_links
    text = "Check out [Google](https://google.com) and [GitHub](https://github.com)"
    expected = 'Check out <a href="https://google.com">Google</a> and <a href="https://github.com">GitHub</a>'
    assert_equal expected, convert_markdown_links_to_html(text)
  end

  def test_prevents_redos_attacks
    # Test patterns from CodeQL alert that could cause ReDoS
    redos_patterns = [
      "[" + "[" * 100,
      "[text](" + "(" * 100,
      "[[[[[[[[[[[[[[[[[[[[[[[",
      "[\]((\]((\]((\]((\]((",
    ]
    
    redos_patterns.each do |pattern|
      start_time = Time.now
      result = convert_markdown_links_to_html(pattern)
      duration = Time.now - start_time
      
      # Should complete very quickly (much less than 1 second)
      assert duration < 0.1, "Pattern '#{pattern[0..20]}...' took #{duration}s (should be < 0.1s)"
      
      # Should return the original text unchanged (no valid markdown links)
      assert_equal pattern, result
    end
  end

  def test_rejects_unsafe_urls
    unsafe_cases = [
      "[link](javascript:alert('xss'))",
      "[link](data:text/html,<script>alert('xss')</script>)",
      "[link](invalid-url)",
      "[link]()",
    ]
    
    unsafe_cases.each do |test_case|
      result = convert_markdown_links_to_html(test_case)
      # Should not convert unsafe URLs to HTML links
      assert_equal test_case, result, "Unsafe URL should not be converted: #{test_case}"
    end
  end

  def test_handles_edge_cases_safely
    edge_cases = [
      "Normal text without links",
      "[incomplete link",
      "incomplete link](https://example.com)",
      "[link with no url]()",
      "[](https://example.com)",
      "[very very very very very very very very very very very very very very very very very very very very very very very very very very very very very very very long link text](https://example.com)",
    ]
    
    edge_cases.each do |test_case|
      # Should not crash or take excessive time
      start_time = Time.now
      result = convert_markdown_links_to_html(test_case)
      duration = Time.now - start_time
      
      assert duration < 0.1, "Edge case took too long: #{duration}s"
      assert_kind_of String, result
    end
  end

  def test_limits_work_correctly
    # Test the 100 character limit for link text
    long_text = "a" * 101
    long_text_case = "[#{long_text}](https://example.com)"
    result = convert_markdown_links_to_html(long_text_case)
    assert_equal long_text_case, result, "Should not convert links with text longer than 100 chars"
    
    # Test the 200 character limit for URLs
    long_url = "https://example.com/" + "a" * 200
    long_url_case = "[link](#{long_url})"
    result = convert_markdown_links_to_html(long_url_case)
    assert_equal long_url_case, result, "Should not convert links with URLs longer than 200 chars"
  end
end