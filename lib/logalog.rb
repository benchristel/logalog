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
    def initialize(block_or_method_name, receiver=nil)
      if block_or_method_name.is_a? Proc
        @block = block_or_method_name
      else
        @method = block_or_method_name
        @receiver = receiver
      end
    end
    
    def call(*args)
      if @block
        @block.call(*args)
      elsif @method && @receiver
        if @receiver.methods.include? @method
          @receiver.send @method, *args
        elsif @receiver.class.methods.include? @method
          @receiver.class.send @method, *args
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
      @before_callbacks << Callback.new(callback || block, @receiver)
    end
    
    def after(callback=nil, &block)
      @after_callbacks << Callback.new(callback || block, @receiver)
    end
    
    def on_exception(callback=nil, &block)
      @on_exception_callbacks << Callback.new(callback || block, @receiver)
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
        cb.call build_callback_params(receiver, @method, args, block, params)
      end
    end
    
    def build_callback_params(receiver, method, args, block, params={})
      { :receiver     => receiver,
        :method       => method,
        :args         => args,
        :arguments    => args,
        :block        => block,
        :exception    => nil,
        :return_value => nil,
      }.merge(params)
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
      # information about the method that triggered the callback. For example:
      #
      #     def log_before_my_method(params)
      #       params[:method]    # => :my_method
      #       params[:receiver]  # => an instance of this class
      #       params[:arguments] # => args passed to my_method
      #       params[:block]     # => block passed to my_method
      #     end
      #
      # Callback methods may be defined as instance methods or class methods.
      # If Logalog can't find an instance method with the callback name, it will
      # look for a class method. If no callback is found, it will raise a
      # NoMethodError.
      #
      # It is possible to use Logalog without defining any callbacks yourself.
      # You can call logalog with no block to use the default callbacks. If you
      # take this route you should specify a logger and method for Logalog to use.
      #
      #     logalog_use_logger Rails.logger, :info
      #     logalog :my_method  # use default logging
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
        
        yield method_interceptor
        
        @_logalog_method_interceptors[method_type][method] = method_interceptor
      end
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
  end
end











class Bank
  include Logalog
  
  def initialize
    @bank_accounts = []
  end
  
  def register_account(account)
    @bank_accounts << account
  end
  
  def transfer(src_account_nbr, dest_account_nbr, amount)
    src =  @bank_accounts.select { |b| b.account_number == src_account_nbr  }.first
    dest = @bank_accounts.select { |b| b.account_number == dest_account_nbr }.first
    src.debit(amount)
    dest.credit(amount)
    amount
  end
  
  logalog 'self.new', 'register_account', 'transfer' do |method|
    method.before { |params| puts "calling #{params[:method]} on #{params[:receiver]} with #{params[:args]}" }
    method.after  { |params| puts "returned #{params[:return_value].inspect} from #{params[:method]} on #{params[:receiver]}" }
  end
  
  logalog 'transfer' do |method|
    method.on_exception { puts "transfer raised exception!" }
  end
  
  logalog 'self.new' do |method|
    method.before { puts "initializing new bank account" }
    method.after  { puts "initialized!" }
  end
end

class BankAccount
  include Logalog
  
  @@last_account_number = 0
  
  attr_accessor :account_number, :balance
  
  def initialize initial_balance = 0
    self.account_number = @@last_account_number + 1
    @@last_account_number = account_number
    
    self.balance = initial_balance
  end
  
  def credit(amount)
    self.balance += amount
  end
  
  def debit(amount)
    if self.balance >= amount
      self.balance -= amount
    else
      raise 'insufficient funds'
    end
  end
  
  def instance_cb
    puts "instance callback on #{self}"
  end
  
  def self.boogie
    puts "OH YEAH"
  end
  
  def self.bill_and_ted
    puts "Most excellent!!!"
  end
  
  logalog 'self.boogie' do |method|
    method.before { |p| puts ">>> #{p[:receiver]} is about to boogie" }
    method.after { |p| puts ">>> #{p[:receiver]} is done with boogie" }
  end
  
  logalog 'self.bill_and_ted' do |method|
    method.before { |p| puts ">>> ..." }
    method.after { |p| puts ">>> !!!" }
  end
  
  logalog :account_number=, :balance= do |method|
    method.before :instance_cb
    method.before { |params| puts "set #{params[:method]} #{params[:args].first}" }
    method.after  { |params| puts "finished setting #{params[:method]} #{params[:args].first}" }
  end
  
  logalog :initialize do |method|
    method.before { |params| puts "initializing BankAccount with #{params[:args].inspect}" }
  end 
end

puts "----- about to call Bank.new -----"
bank = Bank.new

puts "----- about to add bank accounts -----"
b1 = BankAccount.new 100
b2 = BankAccount.new 200

bank.register_account b1
bank.register_account b2

puts "----- about to do a transfer -----"

bank.transfer(1, 2, 50)

puts "----- this transfer will fail -----"

bank.transfer(1, 2, 1000)