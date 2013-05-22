#!/usr/bin/env ruby
# This quick and dirty script imports posts and images exported by the
# Posterous backup feature into Octopress.  Requires the escape_utils and
# nokogiri gems.  Doesn't import comments.
#
# Videos and images are copied into a post-specific image directory used
# by my customized Octopress setup.  Encoded videos are downloaded from
# Posterous.  Images will probably need to be compressed/optimized afterward.
#
# Links to other posts in the same import will try to be converted.  You will
# need to edit the generate_* functions below if your permalink format is
# different from /:year/:month/:day/:title/.
#
# Links, images, videos, special characters/question marks, etc. should be
# verified after running this script.
#
# Posterous seems to have broken any UTF-8 characters in the exported
# wordpress_export_1.xml, but you can work around this by concatenating all the
# *.xml files under posts/ and replacing all <item> tags in
# wordpress_export_1.xml with the concatenated <item> tags from posts/*.xml.
# You may also want to remove all CR characters from the .xml file first.
#
# Run from the base directory of your Octopress setup.
#
# Usage:
# 	cd [octopress_base_dir]
# 	./posterous_import.rb /path/to/wordpress_export_1.xml [base_path]
# 	./posterous_import.rb --links /path/to/wordpress_export_1.xml [base_path]
#
# base_path is the base path of your blog's URLs (e.g. '/' or '/blog').
#
# The --links invocation generates a directory and index.html under source/ for
# each Posterous permalink, allowing an old Posterous domain to be setup with
# 301 redirects to new post locations.  The --links invocation does not import
# any posts.  This is useful if you use a permalink format that differs from
# Posterous's (which is the default behavior).
#
# This script is not guaranteed to work with any Posterous archive other than
# my own.  Do what you want with this script; attribution is appreciated, but
# optional.  Comments and corrections are welcome.
#
# In hindsight it may have been easier to fix up the archived HTML posts or
# individual XML files instead of using the RSS feed.
#
# Created 2013 by Mike Bourgeous - Released under CC0

require 'rss'
require 'yaml'
require 'fileutils'
require 'escape_utils'
require 'nokogiri'

# Fixes references to Posterous in document tags of the given type.  Only
# attributes that appear to contain a Posterous URL will be processed.
#
# If no block is given, tries to find a file matching the tag's attribute under
# [srcdir], or if [srcdir] is nil, downloads the URI contained in [attr].  The
# matching file, if one is found, will be copied into [destdir], and the tag's
# [attr] attribute changed to point at [serverdir]/filename.  Posterous image
# name abbreviation is taken into account, but this has not been tested with a
# wide variety of names.
#
# If a block is given, the block will be called once for each matching tag and
# the contents of its [attr] attribute, and the return value of the block used
# to replace the tag's [attr] attribute.
#
# After the attribute is updated, an immediately surrounding <a> tag linking to
# Posterous, if one exists, will be removed.
#
# doc - The parsed Nokogiri document.
# srcdir - The directory in which to find replacement files, or nil to download
# the originals.
# destdir - The directory to which to copy replacement files.
# serverdir - The name of destdir on the server (used for updating image tags).
# tag - The name of the tags to update.
# attr - The attribute of the tags to update.
def fix_sources doc, srcdir, destdir, serverdir, tag='img', attr='src', &bl
	puts "\tFixing #{tag} tags' #{attr} attribute"

	tags = doc.css(tag)
	postregex = %r{https?://[^/]*posterous.com/}
	tags.each do |img|
		next unless img[attr] =~ postregex

		shortname = img[attr].split('/').last.split('.scaled').first
		ext = shortname.split('.').last.downcase
		puts "\t#{tag}: #{shortname}"

		if block_given?
			img[attr] = yield img, img[attr]
		else
			if srcdir == nil
				# Download the file
				puts "\t\tDownloading #{shortname}"
				File.open(File.join(destdir, shortname), "w") do |file|
					file.write(URI.parse(img[attr]).read)
				end
				in_img = shortname
			else
				# Find matching files
				matches = Dir.entries(srcdir).select {|imgfile|
					imgfile.downcase.end_with?(ext) &&
						imgfile.gsub(/\s+/, '_').include?(shortname.split('.').first)
				}

				if matches.length == 0
					matches = Dir.entries(srcdir).select {|imgfile|
						imgfile.gsub(/\s+/, '_').include?(shortname.split('.').first)
					}
					if matches.length == 0
						puts "\n\n\n########\nNo match found for #{img[attr]} in #{srcdir}\n########\n\n"
						next
					end
				end
				if matches.length > 1
					reduced = matches.select {|imgfile|
						imgfile.include?(shortname)
					}
					if reduced.length == 1
						matches = reduced
					else
						puts "\n\n\n########\nMore than one match found for #{shortname}:"
						puts matches
						puts "You will need to double-check #{tag} tags in #{filename}\n\n"
					end
				end

				in_img = matches.first

				puts "\t\tUsing #{in_img} for #{shortname}"

				# Copy the file into the destination directory
				FileUtils.cp(File.join(srcdir, in_img), destdir)
			end

			# Update the tag's attribute
			img[attr] = EscapeUtils.escape_uri(File.join(serverdir, in_img))
		end

		# Remove a link wrapping the image, if one exists
		parent = img.parent
		if parent.node_name == 'a' && parent['href'] =~ postregex
			puts "\t\tRemoving parent link: #{parent['href']}"
			parent.replace(img)
		end
	end
end

# Writes each item from the given RSS feed into ./source/_posts (use Dir.chdir
# to change directories first if necessary).  Posts will be marked as
# unpublished if the post's link starts with '/private/'.
#
# rss - The File containing the RSS feed.  The images will be found relative to
# 	the feed.
# basedir - The server directory in which the blog's posts and images/
# 	directory reside.
def generate_posts rss_file, basedir='/'
	basedir = "/#{basedir}" unless basedir.start_with? '/'
	basedir = "#{basedir}/" unless basedir.end_with? '/'

	dir = File.dirname(File.expand_path(rss_file))
	rss = File.read(rss_file)

	feed = RSS::Parser.parse(rss, false)

	item_map = Hash[*feed.items.map{|item|
		link = item.link.split('/').last
		[link, {:item => item, :filename => item.pubDate.strftime("source/_posts/%Y-%m-%d-#{link}.html")}]
	}.flatten]

	feed.items.each do |item|
		post_uri = URI.parse(item.link)

		permalink = item.link.split('/').last
		filename = item_map[permalink][:filename]
		date = item.pubDate
		header = {
			'layout' => "post",
			'title' => item.title,
			'date' => date,
			'comments' => true,
			'categories' => item.categories.select{|cat| cat.domain == "tag"}.map{|cat| cat.content},
			'published' => !post_uri.path.start_with?('/private/')
		}

		puts "Generating #{filename}#{header['published'] ? '' : ' (unpublished)'}"

		imgdir = "source/images/#{date.strftime('%Y/%m/%d')}/#{permalink}/"
		serverdir = '/' + imgdir.split('/', 2).last
		FileUtils.mkdir_p(imgdir)

		outfile = File.new(filename, "w")
		outfile.puts header.to_yaml
		outfile.puts "---"

		# Fix up images and video
		html = Nokogiri::HTML("<div id=\"import_#{permalink}\">#{EscapeUtils.unescape_html(item.content_encoded)}</div>")
		images = html.css('img')
		fix_sources html, date.strftime("#{dir}/image/%Y/%m"), imgdir, serverdir
		fix_sources html, nil, imgdir, serverdir, 'source'
		fix_sources html, nil, nil, nil, 'video', 'poster' do nil end

		# Fix up links to other posts
		fix_sources html, nil, nil, nil, 'a', 'href' do |tag, href|
			link_uri = URI.parse(href)
			next unless post_uri.host == link_uri.host

			link_shortname = href.split('/').last.split('#').first
			if item_map.include? link_shortname
				link = item_map[link_shortname][:item]
				href = link.pubDate.strftime("#{basedir}%Y/%m/%d/#{link_shortname}/")
				href += "##{link_uri.fragment}" if link_uri.fragment
				puts "\t\tUsing #{link.title} (#{href})"
			else
				puts "\t######## No match found for #{href}"
			end

			href
		end

		outfile.puts html.css("div#import_#{permalink}").first.children.map{|node| node.to_html}.join
		outfile.close
	end

	nil
end

# Generates a redirecting link from the permalink of each item from the given
# RSS feed to the corresponding post generated by generate_posts().
#
# rss - The File containing the RSS feed.
# basedir - The server directory in which the blog's posts and images/
# 	directory reside.
def generate_links rss_file, basedir='/'
	basedir = "/#{basedir}" unless basedir.start_with? '/'
	basedir = "#{basedir}/" unless basedir.end_with? '/'

	dir = File.dirname(File.expand_path(rss_file))
	rss = File.read(rss_file)

	feed = RSS::Parser.parse(rss, false)

	item_map = Hash[*feed.items.map{|item|
		link = item.link.split('/').last
		[link, {:item => item, :filename => item.pubDate.strftime("source/#{link}/index.html")}]
	}.flatten]

	feed.items.each do |item|
		post_uri = URI.parse(item.link)

		permalink = item.link.split('/').last
		filename = item_map[permalink][:filename]
		dirname = File.dirname(filename)
		href = item.pubDate.strftime("#{basedir}%Y/%m/%d/#{permalink}/")
		title = item.title

		FileUtils.mkdir_p(dirname)
		outfile = File.new(filename, "w")
		outfile.write <<-HTML
		<!DOCTYPE html>
		<html>
			<head>
				<title>#{title}</title>
				<meta http-equiv="Refresh" content="0; url=#{href}">
				<link href="#{basedir}stylesheets/screen.css" rel="stylesheet" type="text/css">
			</head>
			<body>
				<a style="color: inherit; text-decoration: none" href="#{href}">#{title}</a>
			</body>
		</html>
		HTML
		outfile.close
	end

	nil
end


if __FILE__ == $0
	raise 'No RSS feed given' unless $ARGV.length > 0
	if $ARGV[0] == '--links'
		raise 'No RSS feed given' unless $ARGV.length > 1
		generate_links $ARGV[1], $ARGV[2] || '/'
	else
		generate_posts $ARGV[0], $ARGV[1] || '/'
	end
end
