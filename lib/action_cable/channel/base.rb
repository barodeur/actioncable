require 'set'

module ActionCable
  module Channel
    # The channel provides the basic structure of grouping behavior into logical units when communicating over the WebSocket connection.
    # You can think of a channel like a form of controller, but one that's capable of pushing content to the subscriber in addition to simply
    # responding to the subscriber's direct requests.
    #
    # Channel instances are long-lived. A channel object will be instantiated when the cable consumer becomes a subscriber, and then
    # lives until the consumer disconnects. This may be seconds, minutes, hours, or even days. That means you have to take special care
    # not to do anything silly in a channel that would balloon its memory footprint or whatever. The references are forever, so they won't be released
    # as is normally the case with a controller instance that gets thrown away after every request.
    #
    # Long-lived channels (and connections) also mean you're responsible for ensuring that the data is fresh. If you hold a reference to a user
    # record, but the name is changed while that reference is held, you may be sending stale data if you don't take precautions to avoid it.
    #
    # The upside of long-lived channel instances is that you can use instance variables to keep reference to objects that future subscriber requests
    # can interact with. Here's a quick example:
    #
    #   class ChatChannel < ApplicationCable::Channel
    #     def subscribed
    #       @room = Chat::Room[params[:room_number]]
    #     end
    #
    #     def speak(data)
    #       @room.speak data, user: current_user
    #     end
    #   end
    #
    # The #speak action simply uses the Chat::Room object that was created when the channel was first subscribed to by the consumer when that
    # subscriber wants to say something in the room.
    #
    # == Action processing
    #
    # Unlike Action Controllers, channels do not follow a REST constraint form for its actions. It's an remote-procedure call model. You can
    # declare any public method on the channel (optionally taking a data argument), and this method is automatically exposed as callable to the client.
    #
    # Example:
    #
    #   class AppearanceChannel < ApplicationCable::Channel
    #     def subscribed
    #       @connection_token = generate_connection_token
    #     end
    #
    #     def unsubscribed
    #       current_user.disappear @connection_token
    #     end
    #
    #     def appear(data)
    #       current_user.appear @connection_token, on: data['appearing_on']
    #     end
    #
    #     def away
    #       current_user.away @connection_token
    #     end
    #
    #     private
    #       def generate_connection_token
    #         SecureRandom.hex(36)
    #       end
    #   end
    #
    # In this example, subscribed/unsubscribed are not callable methods, as they were already declared in ActionCable::Channel::Base, but #appear/away
    # are. #generate_connection_token is also not callable as its a private method. You'll see that appear accepts a data parameter, which it then
    # uses as part of its model call. #away does not, it's simply a trigger action.
    #
    # Also note that in this example, current_user is available because it was marked as an identifying attribute on the connection.
    # All such identifiers will automatically create a delegation method of the same name on the channel instance.
    class Base
      include Callbacks
      include PeriodicTimers
      include Streams
      include Naming
      include Broadcasting

      SUBSCRIPTION_CONFIRMATION_INTERNAL_MESSAGE = 'confirm_subscription'.freeze

      attr_reader :params, :connection
      delegate :logger, to: :connection

      class << self
        # A list of method names that should be considered actions. This
        # includes all public instance methods on a channel, less
        # any internal methods (defined on Base), adding back in
        # any methods that are internal, but still exist on the class
        # itself.
        #
        # ==== Returns
        # * <tt>Set</tt> - A set of all methods that should be considered actions.
        def action_methods
          @action_methods ||= begin
            # All public instance methods of this class, including ancestors
            methods = (public_instance_methods(true) -
              # Except for public instance methods of Base and its ancestors
              ActionCable::Channel::Base.public_instance_methods(true) +
              # Be sure to include shadowed public instance methods of this class
              public_instance_methods(false)).uniq.map(&:to_s)
            methods.to_set
          end
        end

        protected
          # action_methods are cached and there is sometimes need to refresh
          # them. ::clear_action_methods! allows you to do that, so next time
          # you run action_methods, they will be recalculated
          def clear_action_methods!
            @action_methods = nil
          end

          # Refresh the cached action_methods when a new action_method is added.
          def method_added(name)
            super
            clear_action_methods!
          end
      end

      def initialize(connection, identifier, params = {})
        @connection = connection
        @identifier = identifier
        @params     = params

        # When a channel is streaming via redis pubsub, we want to delay the confirmation
        # transmission until redis pubsub subscription is confirmed.
        @defer_subscription_confirmation = false

        delegate_connection_identifiers
        subscribe_to_channel
      end

      # Extract the action name from the passed data and process it via the channel. The process will ensure
      # that the action requested is a public method on the channel declared by the user (so not one of the callbacks
      # like #subscribed).
      def perform_action(data)
        action = extract_action(data)

        if processable_action?(action)
          dispatch_action(action, data)
        else
          logger.error "Unable to process #{action_signature(action, data)}"
        end
      end

      # Called by the cable connection when its cut so the channel has a chance to cleanup with callbacks.
      # This method is not intended to be called directly by the user. Instead, overwrite the #unsubscribed callback.
      def unsubscribe_from_channel
        run_callbacks :unsubscribe do
          unsubscribed
        end
      end


      protected
        # Called once a consumer has become a subscriber of the channel. Usually the place to setup any streams
        # you want this channel to be sending to the subscriber.
        def subscribed
          # Override in subclasses
        end

        # Called once a consumer has cut its cable connection. Can be used for cleaning up connections or marking
        # people as offline or the like.
        def unsubscribed
          # Override in subclasses
        end

        # Transmit a hash of data to the subscriber. The hash will automatically be wrapped in a JSON envelope with
        # the proper channel identifier marked as the recipient.
        def transmit(data, via: nil)
          logger.info "#{self.class.name} transmitting #{data.inspect}".tap { |m| m << " (via #{via})" if via }
          connection.transmit ActiveSupport::JSON.encode(identifier: @identifier, message: data)
        end


      protected
        def defer_subscription_confirmation!
          @defer_subscription_confirmation = true
        end

        def defer_subscription_confirmation?
          @defer_subscription_confirmation
        end

        def subscription_confirmation_sent?
          @subscription_confirmation_sent
        end

      private
        def delegate_connection_identifiers
          connection.identifiers.each do |identifier|
            define_singleton_method(identifier) do
              connection.send(identifier)
            end
          end
        end


        def subscribe_to_channel
          run_callbacks :subscribe do
            subscribed
          end
          transmit_subscription_confirmation unless defer_subscription_confirmation?
        end


        def extract_action(data)
          (data['action'].presence || :receive).to_sym
        end

        def processable_action?(action)
          self.class.action_methods.include?(action.to_s)
        end

        def dispatch_action(action, data)
          logger.info action_signature(action, data)

          if method(action).arity == 1
            public_send action, data
          else
            public_send action
          end
        end

        def action_signature(action, data)
          "#{self.class.name}##{action}".tap do |signature|
            if (arguments = data.except('action')).any?
              signature << "(#{arguments.inspect})"
            end
          end
        end

        def transmit_subscription_confirmation
          unless subscription_confirmation_sent?
            logger.info "#{self.class.name} is transmitting the subscription confirmation"
            connection.transmit ActiveSupport::JSON.encode(identifier: @identifier, type: SUBSCRIPTION_CONFIRMATION_INTERNAL_MESSAGE)
            @subscription_confirmation_sent = true
          end
        end
    end
  end
end
