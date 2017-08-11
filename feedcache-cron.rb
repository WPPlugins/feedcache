#!/usr/bin/env ruby

# Add the path to your feedcache directory here
FEEDCACHE_DIR = '/path/to/your/wordpress/wp-content/plugins/feedcache'
# How many characters from each feed item do you want to display
CHAR_COUNT = 75
# Set to 'true' if you want to receive error emails from the CRON job
CRON_EMAILS = false
# Update this to your MySQL socket if different
MYSQL_SOCKET = '/tmp/mysql.sock'

#################################################################
#                                                               #
#  DO NOT EDIT BELOW THIS LINE                                  #
#                                                               #
#################################################################
$:.unshift File.join( File.dirname(__FILE__), 'lib', 'feedtools-0.2.29', 'lib' )

require 'rubygems'
require 'active_record'
require 'feed_tools'
require 'yaml'
require 'iconv'

# Read config settings
CONFIG_FILE = "#{FEEDCACHE_DIR}/feedcache-config.yml"
@yaml_config = YAML.load_file( CONFIG_FILE )
WPDB_PREFIX = @yaml_config['db_prefix']
@link_target  = @yaml_config['target_blank'] ? '_blank' : '_self'

ActiveRecord::Base.establish_connection(
  :adapter  => 'mysql',
  :socket   => MYSQL_SOCKET,
  :host     => @yaml_config['db_host'],
  :username => @yaml_config['db_user'],
  :password => @yaml_config['db_password'] || '',
  :database => @yaml_config['db_name']
)

class WPFeed < ActiveRecord::Base
  set_table_name "#{WPDB_PREFIX}feedcache_data"
end

class String
  def to_ascii_iconv
    converter = Iconv.new('ASCII//IGNORE//TRANSLIT', 'UTF-8')
    converter.iconv(self).unpack('U*').select{ |cp| cp < 127 }.pack('U*')
  end
end

# RSS formatting function
def shorten_text(txt)
  if txt.size > CHAR_COUNT
    text = "#{txt} ".slice(0,CHAR_COUNT)
    # need to break on the last space
    if text.include?(' ') and text.slice(text.size-1, 1) != ' '
      text = text.slice(0, text.size - (text.reverse.index(' ') + 1))
      text << '...'
    end
    return text
  else
    return txt
  end
end

begin # parse the config file feed groups
  @all_feeds = {}
  1.upto(@yaml_config['group_num'].to_i) do |num|
    feeds = []
    next if @yaml_config["group#{num}"].nil?
    @yaml_config["group#{num}"].each {|x| feeds << x.strip if (!x.nil? && !x.strip.blank?) }
    @all_feeds[num] = feeds
    feeds = nil
  end
rescue => e
  if CRON_EMAILS
    puts "Error parsing YAML configuration file"
    puts e.inspect
    puts e.backtrace
  end
end  

@all_feeds.each do |k,v|
  tmp = ''
  @processed = 0

  # parse the feeds here
  v.each do |feed|
    html_text = ''
    data = feed.split('|')
    feed_url, feed_title, feed_num, feed_format = data[0], data[1], data[2], data[3]
    begin
      fp = FeedTools::Feed.open(feed_url)
      html_text << @yaml_config['title_pre'] + (feed_title || fp.title || '') + @yaml_config['title_post']
      html_text << "<ul>"
      fp.items.each_with_index do |item, idx|
        break if feed_num ? feed_num.to_i == idx.to_i : @yaml_config['display_num'].to_i == idx.to_i
        output = ''
        output << "<li><a href='#{item.link}' target='#{@link_target}'>"
        item.title.replace(item.title.to_ascii_iconv)
        if feed_format && feed_format == 'true'
          txt = "#{item.title.downcase.gsub(/^[a-z]|\s+[a-z]/) {|a| a.upcase}}"
          output << shorten_text(txt)
        elsif @yaml_config['format_text']
          txt = "#{item.title.downcase.gsub(/^[a-z]|\s+[a-z]/) {|a| a.upcase}}"
          output << shorten_text(txt)
        else
          output << "#{item.title}"
        end
        output << "</a></li>\n"
        html_text << output
      end # end fp.items.each
      html_text << "</ul><br />\n"
      tmp << html_text
      @processed += 1
    rescue => e
      if CRON_EMAILS
        puts "Error processing feed - Group #{k.to_i + 1} - #{feed_url}"
        puts e.inspect
        puts e.backtrace
      end
    end  
  end

  # if we had new feeds, move them to the cache file
  if @processed > 0
    wp_data = WPFeed.find_or_initialize_by_group_id(k)
    wp_data.update_attributes(:data => tmp, :updated_at => Time.now)
  end
end #--> @all_feeds.each do |k,v|
