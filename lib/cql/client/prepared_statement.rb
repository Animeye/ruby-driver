# encoding: utf-8

module Cql
  module Client
    class PreparedStatement
      # Metadata describing the bound values
      #
      # @return [ResultMetadata]
      attr_reader :metadata

      # Metadata about the result (i.e. rows) that is returned when executing
      # this prepared statement.
      #
      # @return [ResultMetadata]
      attr_reader :result_metadata

      # Execute the prepared statement with a list of values to be bound to the
      # statements parameters.
      #
      # The number of arguments must equal the number of bound parameters. You
      # can also specify options as the last argument, or a symbol as a shortcut
      # for just specifying the consistency.
      #
      # Because you can specify options, or not, there is an edge case where if
      # the last parameter of your prepared statement is a map, and you forget
      # to specify a value for your map, the options will end up being sent to
      # Cassandra. Most other cases when you specify the wrong number of
      # arguments should result in an `ArgumentError` or `TypeError` being
      # raised.
      #
      # @param args [Array] the values for the bound parameters. The last
      #   argument can also be an options hash or a symbol (as a shortcut for
      #   specifying the consistency), see {Cql::Client::Client#execute} for
      #   full details.
      # @raise [ArgumentError] raised when number of argument does not match
      #   the number of parameters needed to be bound to the statement.
      # @raise [Cql::NotConnectedError] raised when the client is not connected
      # @raise [Cql::Io::IoError] raised when there is an IO error, for example
      #   if the server suddenly closes the connection
      # @raise [Cql::QueryError] raised when there is an error on the server side
      # @return [nil, Cql::Client::QueryResult, Cql::Client::VoidResult] Some
      #   queries have no result and return `nil`, but `SELECT` statements
      #   return an `Enumerable` of rows (see {Cql::Client::QueryResult}), and
      #   `INSERT` and `UPDATE` return a similar type
      #   (see {Cql::Client::VoidResult}).
      def execute(*args)
      end

      # Yields a batch when called with a block. The batch is automatically
      # executed at the end of the block and the result is returned.
      #
      # Returns a batch when called wihtout a block. The batch will remember
      # the options given and merge these with any additional options given
      # when {Cql::Client::PreparedStatementBatch#execute} is called.
      #
      # The batch yielded or returned by this method is not identical to the
      # regular batch objects yielded or returned by {Cql::Client::Client#batch}.
      # These prepared statement batch objects can be used only to add multiple
      # executions of the same prepared statement.
      #
      # Please note that the batch object returned by this method _is not thread
      # safe_.
      #
      # The type parameter can be ommitted and the options can then be given
      # as first parameter.
      #
      # @example Executing a prepared statement in a batch
      #   statement = client.prepare(%(INSERT INTO metrics (id, time, value) VALUES (?, NOW(), ?)))
      #   statement.batch do |batch|
      #     batch.add(1234, 23423)
      #     batch.add(2346, 13)
      #     batch.add(2342, 2367)
      #     batch.add(4562, 1231)
      #   end
      #
      # @see Cql::Client::PreparedStatementBatch
      # @see Cql::Client::Client#batch
      # @param [Symbol] type the type of batch, must be one of `:logged`,
      #   `:unlogged` and `:counter`. The precise meaning of these  is defined
      #   in the CQL specification.
      # @yieldparam [Cql::Client::PreparedStatementBatch] batch the batch
      # @return [Cql::Client::VoidResult, Cql::Client::Batch] when no block is
      #   given the batch is returned, when a block is given the result of
      #   executing the batch is returned (see {Cql::Client::Batch#execute}).
      def batch(type=:logged, options={})
      end
    end

    # @private
    class AsynchronousPreparedStatement < PreparedStatement
      # @private
      def initialize(cql, execute_options_decoder, connection_manager, logger)
        @cql = cql
        @execute_options_decoder = execute_options_decoder
        @connection_manager = connection_manager
        @logger = logger
        @request_runner = RequestRunner.new
      end

      def self.prepare(cql, execute_options_decoder, connection_manager, logger)
        statement = new(cql, execute_options_decoder, connection_manager, logger)
        futures = connection_manager.map do |connection|
          statement.prepare(connection)
        end
        Future.all(*futures).map(statement)
      rescue => e
        Future.failed(e)
      end

      def execute(*args)
        connection = @connection_manager.random_connection
        if connection[self]
          run(args, connection)
        else
          prepare(connection).flat_map do
            run(args, connection)
          end
        end
      rescue => e
        Future.failed(e)
      end

      def batch(type=:logged, options=nil)
        if type.is_a?(Hash)
          options = type
          type = :logged
        end
        b = AsynchronousBatch.new(type, @execute_options_decoder, @connection_manager, options)
        pb = AsynchronousPreparedStatementBatch.new(self, b)
        if block_given?
          yield pb
          pb.execute
        else
          pb
        end
      end

      # @private
      def prepare(connection)
        prepare_request = Protocol::PrepareRequest.new(@cql)
        f = @request_runner.execute(connection, prepare_request) do |response|
          connection[self] = response.id
          unless @raw_metadata
            # NOTE: this is not thread safe, but the worst that could happen
            # is that we assign the same data multiple times
            @raw_metadata = response.metadata
            @metadata = ResultMetadata.new(@raw_metadata)
            @raw_result_metadata = response.result_metadata
            if @raw_result_metadata
              @result_metadata = ResultMetadata.new(@raw_result_metadata)
            end
          end
          hex_id = response.id.each_byte.map { |x| x.to_s(16).rjust(2, '0') }.join('')
          @logger.debug('Statement %s prepared on node %s (%s:%d)' % [hex_id, connection[:host_id].to_s, connection.host, connection.port])
        end
        f.map(self)
      end

      # @private
      def add_to_batch(batch, connection, bound_args)
        statement_id = connection[self]
        unless statement_id
          raise NotPreparedError
        end
        unless bound_args.size == @raw_metadata.size
          raise ArgumentError, "Expected #{@raw_metadata.size} arguments, got #{bound_args.size}"
        end
        batch.add_prepared(statement_id, @raw_metadata, bound_args)
      end

      private

      def run(args, connection)
        bound_args = args.shift(@raw_metadata.size)
        unless bound_args.size == @raw_metadata.size && args.size <= 1
          raise ArgumentError, "Expected #{@raw_metadata.size} arguments, got #{bound_args.size}"
        end
        options = @execute_options_decoder.decode_options(args.last)
        statement_id = connection[self]
        request_metadata = @raw_result_metadata.nil?
        request = Protocol::ExecuteRequest.new(statement_id, @raw_metadata, bound_args, request_metadata, options[:consistency], options[:serial_consistency], options[:page_size], options[:paging_state], options[:trace])
        f = @request_runner.execute(connection, request, options[:timeout], @raw_result_metadata)
        if options.include?(:page_size)
          f = f.map { |result| AsynchronousPreparedPagedQueryResult.new(self, request, result, options) }
        end
        f
      end
    end

    # @private
    class SynchronousPreparedStatement < PreparedStatement
      include SynchronousBacktrace

      def initialize(async_statement)
        @async_statement = async_statement
        @metadata = async_statement.metadata
        @result_metadata = async_statement.result_metadata
      end

      def execute(*args)
        synchronous_backtrace do
          result = @async_statement.execute(*args).value
          result = SynchronousPagedQueryResult.new(result) if result.is_a?(PagedQueryResult)
          result
        end
      end

      def batch(type=:logged, options=nil, &block)
        if block_given?
          synchronous_backtrace { @async_statement.batch(type, options, &block).value }
        else
          SynchronousPreparedStatementBatch.new(@async_statement.batch(type, options))
        end
      end

      def pipeline
        pl = Pipeline.new(@async_statement)
        yield pl
        synchronous_backtrace { pl.value }
      end

      def async
        @async_statement
      end

      # @private
      def add_to_batch(batch, connection, bound_arguments)
        @async_statement.add_to_batch(batch, connection, bound_arguments)
      end
    end

    # @private
    class Pipeline
      def initialize(async_statement)
        @async_statement = async_statement
        @futures = []
      end

      def execute(*args)
        @futures << @async_statement.execute(*args)
      end

      def value
        Future.all(*@futures).value
      end
    end
  end
end