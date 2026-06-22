# frozen_string_literal: true

require "webrick"
require "json"
require "date"
require_relative "lib/env"
require_relative "lib/notion_gateway"
require_relative "lib/board"
require_relative "lib/scoring"

module Assigner
  # The 4 owners we allocate among (Galen Lin appeared twice in the original
  # ask; Lin CJ added later). Names match Notion `owner` people names.
  CANDIDATE_NAMES = ["Adora Xu", "Lin CJ", "Galen Lin", "Hsiao Jimmy"].freeze
  PORT       = (ENV["ASSIGNER_PORT"] || 4567).to_i
  PUBLIC_DIR = File.expand_path("public", __dir__)

  class Server
    def initialize
      @gateway   = NotionGateway.new(token: Env.token, database_id: Env.database_id)
      @mutex     = Mutex.new
      @board     = nil
      @loaded_at = nil
    end

    # Lazy, cached one-shot scan of the whole DB. Thread-safe.
    def board(refresh: false)
      @mutex.synchronize do
        if @board.nil? || refresh
          warn "[assigner] scanning Notion…"
          pages      = @gateway.scan_all
          @board     = Board.new(pages, candidate_names: CANDIDATE_NAMES, today: Date.today)
          @loaded_at = Time.now.utc.iso8601
          warn "[assigner] scanned #{pages.size} tasks"
        end
        @board
      end
    end

    def start
      srv = WEBrick::HTTPServer.new(
        Port:        PORT,
        BindAddress: "127.0.0.1",
        Logger:      WEBrick::Log.new(File::NULL),
        AccessLog:   []
      )
      srv.mount_proc("/") { |req, res| route(req, res) }
      trap("INT")  { srv.shutdown }
      trap("TERM") { srv.shutdown }
      puts "▶ 派工轉盤 on http://127.0.0.1:#{PORT}  (Stage 1 · dry-run only)"
      srv.start
    end

    private

    def route(req, res)
      case req.path
      when "/"           then static(res, "index.html", "text/html")
      when "/style.css"  then static(res, "style.css",  "text/css")
      when "/app.js"     then static(res, "app.js",     "application/javascript")
      when "/api/tasks"  then api_tasks(req, res)
      when "/api/board"  then api_board(req, res)
      when "/api/score"  then api_score(req, res)
      when "/api/assign" then api_assign(req, res)
      else json(res, 404, { error: "not found" })
      end
    rescue StandardError => e
      json(res, 500, { error: e.message })
    end

    def static(res, name, type)
      file = File.join(PUBLIC_DIR, name)
      return json(res, 404, { error: "missing #{name}" }) unless File.exist?(file)
      res.status = 200
      res["Content-Type"] = "#{type}; charset=utf-8"
      res.body = File.read(file)
    end

    def api_tasks(req, res)
      b = board(refresh: req.query["refresh"] == "1")
      json(res, 200, { tasks: b.candidate_tasks(req.query["q"]), loaded_at: @loaded_at })
    end

    def api_board(_req, res)
      json(res, 200, { candidates: board.aggregates })
    end

    def api_score(req, res)
      task = req.query["task_id"] && board.task(req.query["task_id"])
      return json(res, 404, { error: "task not found" }) unless task

      weights = nil
      if req.query["wa"] && req.query["wfr"] && req.query["wft"]
        weights = { a: req.query["wa"].to_f, fr: req.query["wfr"].to_f, ft: req.query["wft"].to_f }
      end
      temp = (req.query["temp"] || 0.3).to_f

      scoring = Scoring.score(aggregates: board.aggregates, task: task, weights: weights, temperature: temp)
      json(res, 200, { task: task, scoring: scoring })
    end

    # Stage 1: ALWAYS dry-run. No PATCH is ever sent to Notion.
    def api_assign(req, res)
      data = JSON.parse(req.body.to_s.empty? ? "{}" : req.body)
      json(res, 200, {
        dry_run:   true,
        message:   "（dry-run）不會真的寫入 Notion；Stage 3 才接真實寫回。",
        would_set: { task_id: data["task_id"], owner: data["name"], user_id: data["user_id"] },
      })
    end

    def json(res, status, obj)
      res.status = status
      res["Content-Type"] = "application/json; charset=utf-8"
      res.body = obj.to_json
    end
  end
end

Assigner::Server.new.start
