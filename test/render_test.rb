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

  # Additional tests to verify specific content or structure can be added here
end
