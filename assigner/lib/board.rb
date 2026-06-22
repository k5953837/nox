# frozen_string_literal: true

module Assigner
  # Parses raw Notion pages into the shapes the scorer + UI need.
  # Pure transformation over an already-fetched page list (no network).
  class Board
    CLOSED          = ["Done", "Archived"].freeze
    NEEDS_ASSIGN    = ["Pending Assignment", "Not started"].freeze
    TASK_PROP       = "預估點數"
    DOMAIN_PROP     = "Fault Domain"
    TYPE_PROP       = "類型"

    def initialize(pages, candidate_names:, today:)
      @pages      = pages
      @names      = candidate_names
      @today      = today
      @by_id      = {}
      @parsed     = pages.map { |pg| parse(pg) }
      @parsed.each { |t| @by_id[t[:id]] = t }
    end

    # One aggregate per candidate (task-independent signals). Memoized — the
    # underlying pages are immutable for this Board instance.
    def aggregates
      @aggregates ||= compute_aggregates
    end

    def compute_aggregates
      since   = (@today - 14).to_s
      id_map  = id_index
      @names.map do |name|
        agg = { name: name, user_id: id_map[name], open_pts: 0.0, recent: 0,
                total: 0, dom: Hash.new(0), type: Hash.new(0) }
        @parsed.each do |t|
          next unless t[:owner_names].include?(name)
          agg[:total]    += 1
          share           = t[:owner_names].empty? ? 0.0 : t[:pts].to_f / t[:owner_names].size
          agg[:open_pts] += share unless CLOSED.include?(t[:status])
          agg[:recent]   += 1 if t[:created] >= since
          t[:domains].each { |d| agg[:dom][d] += 1 }
          agg[:type][t[:type]] += 1 if t[:type]
        end
        agg[:open_pts] = agg[:open_pts].round(1)
        agg
      end
    end

    # Tasks awaiting an owner, newest first, optional title substring filter.
    def candidate_tasks(query = nil)
      q = query.to_s.strip.downcase
      @parsed
        .select { |t| NEEDS_ASSIGN.include?(t[:status]) }
        .select { |t| q.empty? || t[:title].downcase.include?(q) }
        .sort_by { |t| t[:created] }
        .reverse
        .map { |t| public_task(t) }
    end

    def task(id)
      t = @by_id[id]
      t && public_task(t)
    end

    def id_for(name)
      id_index[name]
    end

    private

    def public_task(t)
      { id: t[:id], title: t[:title], status: t[:status], priority: t[:priority],
        domains: t[:domains], type: t[:type], created: t[:created],
        owners: t[:owner_names], url: t[:url] }
    end

    # name => Notion user id, harvested from owner people objects in the scan.
    def id_index
      @id_index ||= begin
        map = {}
        @parsed.each do |t|
          t[:owners].each { |o| map[o[:name]] ||= o[:id] if o[:name] }
        end
        map
      end
    end

    def parse(pg)
      props   = pg["properties"] || {}
      owners  = (props.dig("owner", "people") || []).map { |p| { id: p["id"], name: p["name"] } }
      {
        id:          pg["id"],
        url:         pg["url"],
        title:       extract_title(props),
        status:      props.dig("Status", "status", "name"),
        priority:    props.dig("Priority", "select", "name"),
        type:        props.dig(TYPE_PROP, "select", "name"),
        domains:     (props.dig(DOMAIN_PROP, "multi_select") || []).map { |o| o["name"] },
        pts:         props.dig(TASK_PROP, "number") || 0,
        created:     (props.dig("Created time", "created_time") || "")[0, 10].to_s,
        owners:      owners,
        owner_names: owners.map { |o| o[:name] }.compact,
      }
    end

    def extract_title(props)
      prop = props["Items"] || props["Name"] || props["Title"] ||
             props.values.find { |v| v.is_a?(Hash) && v["type"] == "title" }
      (prop && prop["title"] || []).map { |t| t["plain_text"] }.join.tap { |s| return "Untitled" if s.empty? }
    end
  end
end
