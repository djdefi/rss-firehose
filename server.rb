#!/usr/bin/env ruby
# frozen_string_literal: true

require 'sinatra'

get '/' do
  File.read(File.join('public', 'index.html'))
end
