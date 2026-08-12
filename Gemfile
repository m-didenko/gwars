source "https://rubygems.org"

ruby "3.2.2"

# Pinned to avoid a native-extension version conflict (concurrent-ruby-ext 1.3.5
# vs concurrent-ruby 1.3.7) present in this machine's rbenv 3.2.2 gem set.
gem "concurrent-ruby", "1.3.5"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 7.1.6"

# The original asset pipeline for Rails [https://github.com/rails/sprockets-rails]
gem "sprockets-rails"

# Use PostgreSQL as the database for Active Record, same adapter in every
# environment so nothing behaves differently only in production.
gem "pg", "~> 1.5"

# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"

# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"

# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"

# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"

# Authentication
gem "devise"
# Force building from source: the precompiled arm64 native gem doesn't match
# this machine's x86_64 Ruby (rbenv 3.2.2 under Rosetta).
gem "bcrypt", force_ruby_platform: true

# Use Redis adapter to run Action Cable in production (config/cable.yml
# already points at it; the gem itself was never actually added before).
# Capped below 6: Rails 7.1's Action Cable adapter still hard-requires
# `gem "redis", ">= 4, < 6"` at runtime and refuses to load otherwise —
# an unbounded requirement here resolves to the newest redis gem and
# breaks Action Cable in production with a LoadError, not a Gemfile error.
gem "redis", ">= 4.0.1", "< 6"

# Use Kredis to get higher-level data types in Redis [https://github.com/rails/kredis]
# gem "kredis"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]


group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ]

  gem "rspec-rails"
  gem "factory_bot_rails"
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"

  # Add speed badges [https://github.com/MiniProfiler/rack-mini-profiler]
  # gem "rack-mini-profiler"

  # Speed up commands on slow machines / big apps [https://github.com/rails/spring]
  # gem "spring"
end

