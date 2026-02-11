# frozen_string_literal: true

require "dotenv/load"
require "notion-ruby-client"
require "tty-reader"
require "tty-cursor"
require "tty-screen"
require "tty-box"
require "tty-table"
require "pastel"

require_relative "nox/version"
require_relative "nox/client"
require_relative "nox/task"
require_relative "nox/board"
require_relative "nox/renderer"
require_relative "nox/app"

module Nox
  class Error < StandardError; end
end
