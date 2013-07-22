# logalog

Logalog is a mixin designed to let you log method calls and exceptions without cluttering up your code.

The following code will create a User class that prints to the console whenever the `sign_in` method is called.

```ruby
require 'logalog'

class User
  include Logalog

  def sign_in
    # ... implementation without logging goes here
  end

  logalog :sign_in do |method|
    method.after { puts "signed in!" }
  end
end
```

You can use either blocks or callback methods with Logalog hooks.

```ruby
  def after_sign_in_callback
    puts "#{self} signed in!"
  end

  logalog :sign_in do |method|
    method.before { puts "about to sign in" }
    method.after :after_sign_in_callback
  end
```

You can also pass multiple method names to `logalog` to define the same callbacks on each. By defining callback methods or blocks that take a parameter, you can get information about the method call.

```ruby
  logalog :sign_in, :sign_out do |method|
    method.after do |call|
      puts "#{call.receiver} got #{call.method} with #{call.args}"
    end
  end
```

Logalog provides default logging behavior to get you up and running quickly. By default it is disabled; you can turn it on by calling `enable_default_logalog_callbacks` in your class.

```ruby
require 'logalog'

class User
  include Logalog
  
  enable_default_logalog_callbacks :before, :after

  def sign_in
    # ... implementation without logging goes here
  end

  logalog :sign_in
end
```

You can define the `logalog_default_before_callback`, `logalog_default_after_callback`, and `logalog_default_on_exception_callback` methods on your class (or in a module that you include in many classes) to override the built-in defaults and provide common logging behavior across many classes.