# frozen_string_literal: true

module Assigner
  # Reads the shared nox .env (NOTION_TOKEN / NOTION_DATABASE_ID).
  # Zero dependencies — no dotenv gem, no bundler.
  module Env
    module_function

    def vars
      @vars ||= parse(env_path)
    end

    def token
      vars.fetch("NOTION_TOKEN") { abort("[assigner] NOTION_TOKEN missing in #{env_path}") }
    end

    def database_id
      vars.fetch("NOTION_DATABASE_ID") { abort("[assigner] NOTION_DATABASE_ID missing in #{env_path}") }
    end

    def env_path
      # assigner/lib/env.rb -> repo root .env
      File.expand_path("../../.env", __dir__)
    end

    def parse(path)
      abort("[assigner] .env not found at #{path}") unless File.exist?(path)
      out = {}
      File.foreach(path) do |line|
        line = line.strip
        next if line.empty? || line.start_with?("#")
        k, v = line.split("=", 2)
        next unless k && v
        out[k.strip] = v.strip.gsub(/\A["']|["']\z/, "")
      end
      out
    end
  end
end
