# encoding: utf-8
require 'eventmachine'
require 'em-synchrony'
require 'em-synchrony/fiber_iterator'
require 'em-http-request'
require 'oj'
require 'date'
require 'tempfile'
require 'fastimage'

require 'telegram/config'
require 'telegram/auth_properties'
require 'telegram/authorization'
require 'telegram/cli_arguments'
require 'telegram/logger'
require 'telegram/connection'
require 'telegram/connection_pool'
require 'telegram/callback'
require 'telegram/api'
require 'telegram/models'
require 'telegram/events'
require 'ext/string'

module Telegram
  # Telegram Client
  #
  # @see API
  # @version 0.1.1
  class Client < API
    include Logging

    # @return [ConnectionPool] Socket connection pool, includes {Connection}
    # @since [0.1.0]
    attr_reader :connection

    # @return [TelegramContact] Current user's profile
    # @since [0.1.0]
    attr_reader :profile

    # @return [Array<TelegramContact>] Current user's contact list
    # @since [0.1.0]
    attr_reader :contacts

    # @return [Array<TelegramChat>] Chats that current user joined
    # @since [0.1.0]
    attr_reader :chats

    attr_reader :stdout

    # Event listeners that can respond to the event arrives
    #
    # @see EventType
    # @since [0.1.0]
    attr_accessor :on, :auth_properties, :confirm_failure_callback

    # Initialize Telegram Client
    #
    # @yieldparam [Block] block
    # @yield [config] Given configuration struct to the block
    def initialize(&block)
      @config = Telegram::Config.new
      @auth_properties = Telegram::AuthProperties.new
      yield @config, @auth_properties
      @logger = @config.logger if @config.logger
      @connected = 0
      @stdout = nil
      @connect_callback = nil
      @on = {}

      @profile = nil
      @contacts = []
      @chats = []
      @starts_at = nil
      @events = EM::Queue.new

      logger.info("Initialized")
    end

    # Execute telegram-cli daemon and wait for the response
    #
    # @api private
    def execute
      cli_arguments = Telegram::CLIArguments.new(@config)
      command = "'#{@config.daemon}' #{cli_arguments.to_s}"
      @stdout = IO.popen(command, 'a+')
      initialize_stdout_reading
    end

    # Do the long-polling from stdout of the telegram-cli
    #
    # @api private
    def poll
      logger.info("Start polling for events")
      while (data = @stdout.gets)
        begin
          brace = data.index('{')
          data = data[brace..-2]
          data = Oj.load(data, mode: :compat)
          @events << data
        rescue
        end
      end
    end

    # Process given data to make {Event} instance
    #
    # @api private
    def process_data
      process = Proc.new { |data|
        begin
          type = case data['event']
          when 'message'
            if data['from']['peer_id'] != @profile.id
              EventType::RECEIVE_MESSAGE
            else
              EventType::SEND_MESSAGE
            end
          end

          action = data.has_key?('action') ? case data['action']
            when 'chat_add_user'
              ActionType::CHAT_ADD_USER
            when 'create_group_chat'
              ActionType::CREATE_GROUP_CHAT
             when 'add_contact'
               ActionType::ADD_CONTACT
            else
              ActionType::UNKNOWN_ACTION
            end : ActionType::NO_ACTION

          event = Event.new(self, type, action, data)
          @on[type].call(event) if @on.has_key?(type)
        rescue Exception => e
          logger.error("Error occurred during the processing: #{data}\n #{e.inspect} #{e.backtrace}")
        end
        @events.pop(&process)
      }
      @events.pop(&process)
    end

    # Start telegram-cli daemon
    #
    # @yield This block will be executed when all connections have responded
    def connect(&block)
      logger.info("Trying to start telegram-cli and then connect")
      @connect_callback = block
      process_data
      EM.defer(method(:execute), method(:create_pool), method(:execution_failed))
    end

    # Create a connection pool based on the {Connection} and given configuration
    #
    # @api private
    def create_pool(*)
      @connection = ConnectionPool.new(@config.size) do
        client = EM.connect_unix_domain(@config.sock, Connection)
        client.on_connect = self.method(:on_connect)
        client.on_disconnect = self.method(:on_disconnect)
        client
      end
    end

    # A event listener that will be called if the {Connection} successes on either of {ConnectionPool}
    #
    # @api private
    def on_connect
      @connected += 1
      if connected?
        logger.info("Successfully connected to the Telegram CLI")
        EM.defer(&method(:poll))
        update!(&@connect_callback)
      end
    end

    # A event listener that will be called if the {Connection} closes on either of {ConnectionPool}
    #
    # @api private
    def on_disconnect
      @connected -= 1
      if @connected == 0
        logger.info("Disconnected from Telegram CLI")
        close_stdout
        @disconnect_callback.call if @disconnect_callback
      end
    end

    def on_disconnect=(callback)
      @disconnect_callback = callback
    end

    # @return [bool] Connection pool status
    # @since [0.1.0]
    def connected?
      @connected == @config.size
    end

    private

    def execution_failed(e)
	  @confirm_failure_callback.call
      logger.error("Failed execution of telegram-cli: #{e}")
      close_stdout
    end

    def close_stdout
      Process.kill('INT', stdout.pid)
    end

    def initialize_stdout_reading
      return stdout.readline unless auth_properties.present?
      Authorization.new(stdout, auth_properties, logger).perform
    end
  end
end
