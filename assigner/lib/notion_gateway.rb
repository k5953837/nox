# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Assigner
  # Thin, pure-I/O wrapper over the Notion REST API (stdlib net/http only).
  # No business logic lives here.
  class NotionGateway
    API     = "https://api.notion.com/v1"
    VERSION = "2022-06-28"

    def initialize(token:, database_id:)
      @token = token
      @db    = database_id
    end

    # Returns ALL raw page hashes in the database (paginated).
    def scan_all
      results = []
      cursor  = nil
      loop do
        body = { page_size: 100 }
        body[:start_cursor] = cursor if cursor
        json = post("/databases/#{@db}/query", body)
        results.concat(json["results"] || [])
        break unless json["has_more"]
        cursor = json["next_cursor"]
      end
      results
    end

    # Stage 1: present but NEVER called by the server (write-back is dry-run only).
    # Wired for Stage 3.
    def patch_owner(page_id, user_ids)
      people = user_ids.map { |id| { object: "user", id: id } }
      patch("/pages/#{page_id}", { properties: { "owner" => { people: people } } })
    end

    private

    def post(path, body)
      http(Net::HTTP::Post, path, body)
    end

    def patch(path, body)
      http(Net::HTTP::Patch, path, body)
    end

    def get(path)
      http(Net::HTTP::Get, path, nil)
    end

    def http(klass, path, body)
      uri = URI("#{API}#{path}")
      req = klass.new(uri)
      req["Authorization"]  = "Bearer #{@token}"
      req["Notion-Version"] = VERSION
      req["Content-Type"]   = "application/json"
      req.body = body.to_json if body
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
      unless res.code.start_with?("2")
        raise "Notion API #{res.code}: #{res.body.to_s[0, 300]}"
      end
      JSON.parse(res.body)
    end
  end
end
