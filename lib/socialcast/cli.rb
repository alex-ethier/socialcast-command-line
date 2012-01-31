require 'rubygems'

require "thor"
require 'json'
require 'rest_client'
require 'highline'
require 'socialcast'
require 'socialcast/message'
require File.join(File.dirname(__FILE__), 'net_ldap_ext')

require 'zlib'
require 'logger'
require 'builder'
require 'net/ldap'

module Socialcast
  class CLI < Thor
    include Thor::Actions

    method_option :trace, :type => :boolean, :aliases => '-v'
    def initialize(*args); super(*args) end

    desc "authenticate", "Authenticate using your Socialcast credentials"
    method_option :user, :type => :string, :aliases => '-u', :desc => 'email address for the authenticated user'
    method_option :password, :type => :string, :aliases => '-p', :desc => 'password for the authenticated user'
    method_option :domain, :type => :string, :default => 'api.socialcast.com', :desc => 'Socialcast community domain'
    method_option :proxy, :type => :string, :desc => 'HTTP proxy options for connecting to Socialcast server'
    def authenticate
      user = options[:user] || ask('Socialcast username: ')
      password = options[:password] || HighLine.new.ask("Socialcast password: ") { |q| q.echo = false }
      domain = options[:domain]

      url = ['https://', domain, '/api/authentication.json'].join
      say "Authenticating #{user} to #{url}"
      params = {:email => user, :password => password }
      RestClient.log = Logger.new(STDOUT) if options[:trace]
      RestClient.proxy = options[:proxy] if options[:proxy]
      resource = RestClient::Resource.new url
      response = resource.post params
      say "API response: #{response.body.to_s}" if options[:trace]
      communities = JSON.parse(response.body.to_s)['communities']
      domain = communities.detect {|c| c['domain'] == domain} ? domain : communities.first['domain']

      Socialcast.credentials = {:user => user, :password => password, :domain => domain, :proxy => options[:proxy]}
      say "Authentication successful for #{domain}"
    end

    desc "share MESSAGE", "Posts a new message into socialcast"
    method_option :url, :type => :string, :desc => '(optional) url to associate to the message'
    method_option :message_type, :type => :string, :desc => '(optional) force an alternate message_type'
    method_option :attachments, :type => :array, :default => []
    def share(message = nil)
      message ||= $stdin.read_nonblock(100_000) rescue nil

      attachment_ids = []
      options[:attachments].each do |path|
        Dir[File.expand_path(path)].each do |attachment|
          say "Uploading attachment #{attachment}..."
          uploader = Socialcast.resource_for_path '/api/attachments.json', {}, options[:trace]
          uploader.post :attachment => File.new(attachment) do |response, request, result|
            if response.code == 201
              attachment_ids << JSON.parse(response.body)['attachment']['id']
            else
              say "Error uploading attachment: #{response.body}"
            end
          end
        end
      end

      Socialcast::Message.configure_from_credentials
      Socialcast::Message.create :body => message, :url => options[:url], :message_type => options[:message_type], :attachment_ids => attachment_ids

      say "Message has been shared"
    end

    desc 'provision', 'provision users from ldap compatible user repository'
    method_option :config, :default => 'ldap.yml', :aliases => '-c'
    method_option :output, :default => 'users.xml.gz', :aliases => '-o'
    method_option :setup, :type => :boolean
    method_option :delete_users_file, :type => :boolean
    method_option :test, :type => :boolean
    method_option :skip_emails, :type => :boolean
    def provision
      config_file = File.expand_path options[:config]

      if options[:setup]
        create_file config_file do
          File.read File.join(File.dirname(__FILE__), '..', '..', 'config', 'ldap.yml')
        end
        return
      end

      fail "Unable to load configuration file: #{config_file}" unless File.exists?(config_file)
      say "Using configuration file: #{config_file}"
      config = YAML.load_file config_file
      required_mappings = %w{email first_name last_name}
      mappings = config.fetch 'mappings', {}
      required_mappings.each do |field|
        unless mappings.has_key? field
          fail "Missing required mapping: #{field}"
        end
      end

      permission_mappings = config.fetch 'permission_mappings', {}
      membership_attribute = permission_mappings.fetch 'attribute_name', 'memberof'
      attributes = mappings.values
      attributes << membership_attribute

			count = 0
      output_file = File.join Dir.pwd, options[:output]
      Zlib::GzipWriter.open(output_file) do |gz|
        xml = Builder::XmlMarkup.new(:target => gz, :indent => 1)
        xml.instruct!
        xml.export do |export|
          export.users(:type => "array") do |users|
            config["connections"].each_pair do |key, connection|
              say "Connecting to #{key} at #{[connection["host"], connection["port"]].join(':')}"

              ldap = Net::LDAP.new :host => connection["host"], :port => connection["port"], :base => connection["basedn"]
              ldap.encryption connection['encryption'].to_sym if connection['encryption']
              ldap.auth connection["username"], connection["password"]
              say "Searching base DN: #{connection["basedn"]} with filter: #{connection["filter"]}"

              ldap.search(:return_result => false, :filter => connection["filter"], :base => connection["basedn"], :attributes => attributes) do |entry|
                next if entry.grab(mappings["email"]).blank? || (mappings.has_key?("unique_identifier") && entry.grab(mappings["unique_identifier"]).blank?)

                users.user do |user|
                  entry.build_xml_from_mappings user, mappings, permission_mappings
                end
                count += 1
                say "Scanned #{count} users" if ((count % 100) == 0)
              end # search
            end # connections
          end # users
        end # export
      end # gzip
      say "Finished scanning #{count} users"

      say "Uploading dataset to Socialcast..."
      http_config = config.fetch('http', {})
      resource = Socialcast.resource_for_path '/api/users/provision', http_config
      File.open(output_file, 'r') do |file|
        request_params = {:file => file}
        request_params[:skip_emails] = 'true' if (config['options']["skip_emails"] || options[:skip_emails])
        request_params[:test] = 'true' if (config['options']["test"] || options[:test])
        resource.post request_params
      end
      say "Finished"

      File.delete(output_file) if (config['options']['delete_users_file'] || options[:delete_users_file])
    end
  end
end
