#!/usr/bin/env ruby
require 'sinatra'

get '/' do
  grabrss
  html :index
end

def html(view)
  File.read(File.join('public', "#{view}.html"))
end
