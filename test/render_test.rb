require 'minitest/autorun'
require_relative '../render.rb'

class RenderTest < Minitest::Test
  def setup
    # Setup code to run render.rb and capture output
    @output = `ruby render.rb`
    @expected_output_structure = "<html><head><title>News Firehose</title></head><body>"
  end

  def test_render_output_structure
    assert_includes @output, @expected_output_structure, "The output structure of render.rb does not match the expected HTML structure."
  end

  # Additional tests to verify specific content or structure can be added here
end
