require 'forwardable'

class Pry
  class REPL
    extend Forwardable
    def_delegators :@pry, :input, :output

    # @return [Pry] The instance of {Pry} that the user is controlling.
    attr_accessor :pry

    # Instantiate a new {Pry} instance with the given options, then start a
    # {REPL} instance wrapping it.
    # @option options See {Pry#initialize}
    def self.start(options)
      new(Pry.new(options)).start
    end

    # Create an instance of {REPL} wrapping the given {Pry}.
    # @param [Pry] pry The instance of {Pry} that this {REPL} will control.
    # @param [Hash] options Options for this {REPL} instance.
    # @option options [Object] :target The initial target of the session.
    def initialize(pry, options = {})
      @pry    = pry
      @indent = Pry::Indent.new

      if options[:target]
        @pry.push_binding options[:target]
      end
    end

    # Start the read-eval-print loop.
    # @return [Object?] If the session throws `:breakout`, return the value
    #   thrown with it.
    # @raise [Exception] If the session throws `:raise_up`, raise the exception
    #   thrown with it.
    def start
      prologue
      repl
    ensure
      epilogue
    end

    private

    # Set up the repl session.
    # @return [void]
    def prologue
      pry.exec_hook :before_session, pry.output, pry.current_binding, pry

      # Clear the line before starting Pry. This fixes issue #566.
      if Pry.config.correct_indent
        Kernel.print Pry::Helpers::BaseHelpers.windows_ansi? ? "\e[0F" : "\e[0G"
      end
    end

    # The actual read-eval-print loop.
    #
    # The {REPL} instance is responsible for reading and looping, whereas the
    # {Pry} instance is responsible for evaluating user input and printing
    # return values and command output.
    #
    # @return [Object?] If the session throws `:breakout`, return the value
    #   thrown with it.
    # @raise [Exception] If the session throws `:raise_up`, raise the exception
    #   thrown with it.
    def repl
      loop do
        case val = read(pry.select_prompt)
        when :control_c
          output.puts ""
          pry.reset_eval_string
        when :no_more_input
          output.puts "" if output.tty?
          break
        else
          output.puts "" if val.nil? && output.tty?
          return pry.exit_value unless pry.eval(val)
        end
      end
    end

    # Clean up after the repl session.
    # @return [void]
    def epilogue
      pry.exec_hook :after_session, pry.output, pry.current_binding, pry
    end

    # Read a line of input from the user.
    # @param [String] prompt The prompt to use for input.
    # @return [String] The line entered by the user.
    # @return [nil] On `<Ctrl-D>`.
    # @return [:control_c] On `<Ctrl+C>`.
    # @return [:no_more_input] On EOF.
    def read(prompt)
      @indent.reset if pry.eval_string.empty?

      indentation = Pry.config.auto_indent ? @indent.current_prefix : ''

      val = read_line("#{prompt}#{indentation}")

      if val.is_a? String
        fix_indentation(val, indentation)
      else
        # nil for EOF, :no_more_input for error, or :control_c for <Ctrl-C>
        val
      end
    end

    # Return the next line of input to be sent to the {Pry} instance.
    # @param [String] prompt The prompt to use for input.
    # @return [nil] On `<Ctrl-D>`.
    # @return [:control_c] On `<Ctrl+C>`.
    # @return [:no_more_input] On EOF.
    def read_line(prompt)
      with_error_handling do
        set_completion_proc

        if input == Readline
          input.readline(prompt, false) # false since we'll add it manually
        elsif input.method(:readline).arity == 1
          input.readline(prompt)
        else
          input.readline
        end
      end
    end

    # Wrap the given block with our default error handling ({handle_eof},
    # {handle_interrupt}, and {handle_read_errors}).
    def with_error_handling
      handle_read_errors do
        handle_interrupt do
          handle_eof do
            yield
          end
        end
      end
    end

    private

    # Set the default completion proc, if applicable.
    def set_completion_proc
      if input.respond_to? :completion_proc=
        input.completion_proc = proc do |input|
          @pry.complete input
        end
      end
    end

    # Manage switching of input objects on encountering `EOFError`s.
    # @return [Object] Whatever the given block returns.
    # @return [:no_more_input] Indicates that no more input can be read.
    def handle_eof
      should_retry = true

      begin
        yield
      rescue EOFError
        pry.input = Pry.config.input

        if should_retry
          should_retry = false
          retry
        else
          output.puts "Error: Pry ran out of things to read from! " \
            "Attempting to break out of REPL."
          return :no_more_input
        end
      end
    end

    # Handle `Ctrl-C` like Bash: empty the current input buffer, but don't
    # quit.  This is only for MRI 1.9; other versions of Ruby don't let you
    # send Interrupt from within Readline.
    # @return [Object] Whatever the given block returns.
    # @return [:control_c] Indicates that the user hit `Ctrl-C`.
    def handle_interrupt
      yield
    rescue Interrupt
      return :control_c
    end

    # Deal with any random errors that happen while trying to get user input.
    # @return [Object] Whatever the given block returns.
    # @return [:no_more_input] Indicates that no more input can be read.
    def handle_read_errors
      exception_count = 0

      begin
        yield
      # If we get a random error when trying to read a line we don't want to
      # automatically retry, as the user will see a lot of error messages
      # scroll past and be unable to do anything about it.
      rescue RescuableException => e
        puts "Error: #{e.message}"
        output.puts e.backtrace
        exception_count += 1
        if exception_count < 5
          retry
        end
        puts "FATAL: Pry failed to get user input using `#{input}`."
        puts "To fix this you may be able to pass input and output file " \
          "descriptors to pry directly. e.g."
        puts "  Pry.config.input = STDIN"
        puts "  Pry.config.output = STDOUT"
        puts "  binding.pry"
        return :no_more_input
      end
    end

    def fix_indentation(line, indentation)
      if Pry.config.auto_indent
        original_line = "#{indentation}#{line}"
        indented_line = @indent.indent(line)

        if output.tty? && @indent.should_correct_indentation?
          output.print @indent.correct_indentation(
            prompt, indented_line,
            original_line.length - indented_line.length
          )
          output.flush
        end

        indented_line
      else
        line
      end
    end

  end
end