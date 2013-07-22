module Logalog
  # TODO: names?
  # Bark
  # Chainsaw (taken)
  # Timber (taken)
  # Lumber (taken)
  
  CLASS_METHOD    = :class_method
  INSTANCE_METHOD = :instance_method
  
  class GlobalData
    #   ==========
    # This is a hack to get around the fact that `class << self` does not create
    # a closure. To get variable values into `class << self` from an enclosing
    # scope, we need to use some sort of globally-accessible data store.
    
    @@data = {}

    def self.set *args
      if args.length == 1 && (hash = args.first).is_a?(Hash)
        @@data.merge! hash
      else
        key   = args[0]
        value = args[1]
        @@data[key] = value
      end
    end
    
    def self.get key=nil
      if key.nil?
        @@data
      else
        @@data[key]
      end
    end
    
    def self.[]= key, value
      self.set key, value
    end
    
    def self.[] key
      self.get key
    end
    
    def self.clear
      @@data = {}
    end
  end
  
  class Callback
    def initialize(block_or_method_name)
      if block_or_method_name.is_a? Proc
        @block = block_or_method_name
      else
        @method = block_or_method_name
      end
    end
    
    def call(receiver, *args)
      if @block
        @block.call(*args)
      elsif @method
        if receiver.methods.include? @method
          receiver.send @method, *args
        elsif receiver.class.methods.include? @method
          receiver.class.send @method, *args
        end
      end
    end
  end
  
  class MethodInterceptor
    #   ^^^^^^^^^^^^^^^^^
    # Create a MethodInterceptor instance with
    # - a method name,
    # - a method type (Logalog::CLASS_METHOD or Logalog::INSTANCE_METHOD)
    # - a class
    #
    # and it will let you define `before`, `after`, and `on_exception` callbacks
    # for the method.
    #
    # FREAKING MAGICAL, RIGHT?
    #
    #     class MyClass
    #       def a; puts "a"; end
    #     end
    #
    #     m = Logalog::MethodInterceptor.new(:a, Logalog::INSTANCE_METHOD, MyClass)
    #     m.before { puts "before" }
    #
    #     MyClass.new.a
    #
    # The code above will print the following:
    #
    #     before
    #     a
    #
    def initialize(method_name, method_type, klass)
      @klass       = klass
      @method = method_name
      @before_callbacks = []
      @after_callbacks = []
      @on_exception_callbacks = []
      
      setup_method_alias(klass, method_name, method_type)
    end
    
    def before(callback=nil, &block)
      @before_callbacks << Callback.new(callback || block)
    end
    
    def after(callback=nil, &block)
      @after_callbacks << Callback.new(callback || block)
    end
    
    def on_exception(callback=nil, &block)
      @on_exception_callbacks << Callback.new(callback || block)
    end
    
    def call receiver, args, &block
      do_callbacks(@before_callbacks, receiver, args, block)
      
      return_value = receiver.send "#{@method}_without_autologging", *args, &block
      
      do_callbacks(@after_callbacks, receiver, args, block, :return_value => return_value)
      
      return_value
    rescue NoMethodError => no_method_error
      # we don't want to stop NoMethodErrors from propagating, because they mean
      # that a callback (or the method the callback was set on) was not found.
      raise no_method_error
    rescue Exception => exception
      do_callbacks(@on_exception_callbacks, receiver, args, block, :exception => exception)
      raise exception
      #@after_callback.call  build_callback_params(receiver, @method, args, block, :exception => exception)
    end
    
    private
    
    def setup_method_alias(klass, method, method_type)
      method_with_callbacks_object = self
      _alias = "#{method}_without_autologging"
      klass.class_eval do
        if method_type == CLASS_METHOD
          GlobalData.set(:method => method,
                         :alias => _alias,
                         :method_with_callbacks_object => method_with_callbacks_object
                         )
          class << self
            alias_method  GlobalData.get(:alias), meth = GlobalData.get(:method)
            method_with_callbacks_object = GlobalData.get(:method_with_callbacks_object)
            
            define_method meth do |*args, &block|
              method_with_callbacks_object.call self, args, &block
            end
          end
        else
          alias_method _alias, method
          
          define_method method do |*args, &block|
            method_with_callbacks_object.call self, args, &block
          end
        end
      end
    end
    
    def do_callbacks(callbacks, receiver, args, block, params={})
      callbacks.each do |cb|
        cb.call receiver, build_callback_params(receiver, @method, args, block, params)
      end
    end
    
    module HashInitializable
      def initialize(attrs={})
        attrs.each_pair { |k, v| send("#{k}=", v) }
      end
    end
    
    class Call
      include HashInitializable
      attr_accessor :receiver, :method, :args, :block, :exception, :return_value
    end
    
    def build_callback_params(receiver, method, args, block, params={})
      Call.new({
        :receiver => receiver,
        :method => method,
        :args => args,
        :block => block,
        :exception => nil,
        :return_value => nil,
      }.merge(params))
    end
  end
  
  # Boilerplate for a mixin. We could use ActiveSupport::Concern, but then
  # clients would have to have ActiveSupport::Concern... and some of them don't
  # feel like it.
  def self.included(target)
    target.send(:include, InstanceMethods)
    target.extend ClassMethods
    target.class_eval do
      _logalog_class_eval_on_included
    end
  end

  module InstanceMethods
  end

  module ClassMethods

    def logalog(*methods)
      # ^^^^^^^^^^^^^^^^^
      # Called by clients to wrap the given instance methods in delicious logging.
      # the original methods are aliased so they are still accessible.
      #
      # Takes a block in which the client can specify callbacks for the `before`,
      # `after`, and `on_exception` hooks. Callbacks can be specified as method
      # names, or as blocks. For example:
      #
      #     logalog :my_method do
      #       before :log_before_my_method
      #       after { puts "my_method returned" }
      #       on_exception :handle_exception
      #     end
      #
      # Callback methods should accept a single argument, a hash containing
      # information about the method call that triggered the callback.
      # For example:
      #
      #     def log_before_my_method(call)
      #       call.method    # => :my_method
      #       call.receiver  # => an instance of this class
      #       call.args      # => args passed to my_method
      #       call.block     # => block passed to my_method
      #     end
      #
      # Callback methods may be defined as instance methods or class methods.
      # If Logalog can't find an instance method with the callback name, it will
      # look for a class method. If no callback is found, it will raise a
      # NoMethodError.
      #
      # It is possible to use Logalog without defining any callbacks yourself.
      #
      #     logalog_use_logger Rails.logger, :info
      #     logalog :my_method  # use default logging
      #
      # The above will use the default Logalog callbacks, using the logger you
      # specify to write output.
      #
      # You can implement your own defaults by overriding the
      # `logalog_default_*_callback` methods on your class.
      #
      # # TODO: clients can specify a different logger/method for each callback
      
      methods.each do |method|
        if method.to_s =~ /^self\./
          method_type = CLASS_METHOD
        else
          method_type = INSTANCE_METHOD
        end
        method = method.to_s.gsub(/^self\./, '').to_sym
        
        method_interceptor =
            _logalog_find_or_create_method_interceptor(method, method_type)
        
        if block_given?
          yield method_interceptor
        else
          _logalog_add_default_callbacks(method_interceptor)
        end
        
        @_logalog_method_interceptors[method_type][method] = method_interceptor
      end
    end
    
    def logalog_default_before_callback(call)
      caller = Kernel.caller
      stack_depth = caller.length
      max_indent = 20
      indent_string = if stack_depth > max_indent
        "[logalog] #{(stack_depth).to_s.ljust(4)}" + ">" + " "*(stack_depth % max_indent)
      else
        " "*5 + ">" + " "*stack_depth
      end
      
      c = caller[6].to_s.gsub(/^.*\//, '')
      s = "#{indent_string}#{c} called #{call.receiver}.#{call.method}(#{call.args})"
      
      #_logalog_default_log(:before, s)
      puts s
    end
    
    def logalog_default_after_callback(call)
      stack_depth = Kernel.caller.length
      max_indent = 20
      indent_string = if stack_depth > max_indent
        "[logalog] #{(stack_depth).to_s.ljust(4)}" + "|" + " "*(stack_depth % max_indent)
      else
        " "*5 + "|" + " "*stack_depth
      end
      
      s = "#{indent_string}#{call.receiver}.#{call.method}(#{call.args}) => #{call.return_value}"
      
      #_logalog_default_log(:before, s)
      puts s
    end
    
    def logalog_default_on_exception_callback(call)
      caller = Kernel.caller
      stack_depth = caller.length
      max_indent = 20
      indent_string = if stack_depth > max_indent
        "[logalog] #{(stack_depth).to_s.ljust(4)}" + "|" + " "*(stack_depth % max_indent)
      else
        " "*5 + "#" + " "*stack_depth
      end
      
      s = "#{indent_string}#{call.receiver}.#{call.method}(#{call.args}) raised #{call.exception}"
      
      #_logalog_default_log(:before, s)
      puts s
    end
    
    def _logalog_find_or_create_method_interceptor(method, method_type)
      method_interceptor = @_logalog_method_interceptors[method_type][method]
      method_interceptor ||= MethodInterceptor.new(method, method_type, self)
      @_logalog_method_interceptors[method_type][method] = method_interceptor
    end

    def _logalog_class_eval_on_included
      class_eval do
        @_logalog_method_interceptors = {CLASS_METHOD => {}, INSTANCE_METHOD => {}}
      end
    end
    
    def _logalog_add_default_callbacks(method_interceptor)
      method_interceptor.before :logalog_default_before_callback
      method_interceptor.after  :logalog_default_after_callback
      method_interceptor.on_exception :logalog_default_on_exception_callback
    end
  end
end
