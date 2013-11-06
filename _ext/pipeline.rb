require 'bootstrap-sass'
require 'presentations'

Awestruct::Extensions::Pipeline.new do
  extension Awestruct::Extensions::Posts.new('/blog')
  extension Awestruct::Extensions::Indexifier.new
  # Indexifier *must* come before Atomizer
  extension Awestruct::Extensions::Atomizer.new :posts, '/blog.atom'
  extension Awestruct::Extensions::Disqus.new()

  extension Presentations.new

  helper Awestruct::Extensions::GoogleAnalytics
end
