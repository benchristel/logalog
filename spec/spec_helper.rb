require 'spork'
require 'rspec'

files = Dir.glob(File.expand_path("../../lib/**/*.rb", __FILE__))

files.each do |f|
  require_name = f.gsub(/.rb$/, '')
  require require_name
end
