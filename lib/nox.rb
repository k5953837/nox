# frozen_string_literal: true

require "dotenv/load"
require "notion-ruby-client"
require "ratatui_ruby"
require "time"
require "date"

require_relative "nox/version"
require_relative "nox/selection"
require_relative "nox/client"
require_relative "nox/task"
require_relative "nox/board"
require_relative "nox/app"

module Nox
  class Error < StandardError; end
end
