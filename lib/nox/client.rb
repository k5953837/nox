# frozen_string_literal: true

module Nox
  class Client
    def initialize
      @client = Notion::Client.new(token: ENV.fetch("NOTION_TOKEN"))
      @database_id = ENV.fetch("NOTION_DATABASE_ID")
      @sprints_db_id = ENV.fetch("NOTION_SPRINTS_DB_ID")
    end

    def fetch_sprints
      fetch_all_sprints
    end

    # Detects the current sprint by checking which sprint's date range contains
    # today. Falls back to the Notion "Current" status tag if no date match found.
    def fetch_current_sprint
      today = Date.today.to_s   # "YYYY-MM-DD"
      all   = fetch_all_sprints

      # Primary: find sprint whose [start, end] range contains today
      by_date = all.find do |s|
        start_d = s[:dates]&.dig("start")
        end_d   = s[:dates]&.dig("end")
        next false unless start_d
        start_d <= today && (end_d.nil? || end_d >= today)
      end

      # Fallback: Notion "Current" status (may be stale)
      by_date || all.find { |s| s[:status] == "Current" }
    end

    def fetch_tasks_by_sprint(sprint_id)
      tasks = []
      cursor = nil
      
      loop do
        params = {
          database_id: @database_id,
          page_size: 100,
          filter: { property: "Sprint", relation: { contains: sprint_id } }
        }
        params[:start_cursor] = cursor if cursor
        
        response = @client.database_query(**params)
        response.results.each do |result|
          tasks << Task.from_notion(result)
        end
        break unless response.has_more
        cursor = response.next_cursor
      end
      tasks
    end

    def fetch_tasks
      tasks = []
      cursor = nil
      
      loop do
        params = { database_id: @database_id, page_size: 100 }
        params[:start_cursor] = cursor if cursor
        
        response = @client.database_query(**params)
        response.results.each do |result|
          tasks << Task.from_notion(result)
        end
        break unless response.has_more
        cursor = response.next_cursor
      end
      tasks
    end

    def fetch_users
      users = []
      cursor = nil
      loop do
        params = { page_size: 100 }
        params[:start_cursor] = cursor if cursor
        response = @client.users_list(**params)
        response.results.each do |user|
          next unless user.type == "person"
          users << { id: user.id, name: user.name || "Unknown" }
        end
        break unless response.has_more
        cursor = response.next_cursor
      end
      users.sort_by { |u| u[:name] }
    end

    def update_task_owner(task_id, user_ids)
      people = user_ids.map { |uid| { object: "user", id: uid } }
      @client.update_page(
        page_id: task_id,
        properties: {
          "owner" => { people: people }
        }
      )
    end

    def update_task_status(task_id, new_status)
      @client.update_page(
        page_id: task_id,
        properties: {
          "Status" => { status: { name: new_status } }
        }
      )
    end

    def fetch_sub_tasks(parent_task_id)
      tasks = []
      cursor = nil
      loop do
        params = {
          database_id: @database_id,
          page_size: 100,
          filter: { property: "Parent-task", relation: { contains: parent_task_id } }
        }
        params[:start_cursor] = cursor if cursor
        response = @client.database_query(**params)
        response.results.each { |r| tasks << Task.from_notion(r) }
        break unless response.has_more
        cursor = response.next_cursor
      end
      tasks
    end

    def fetch_page_content(page_id)
      blocks = fetch_all_children(page_id)

      table_blocks = blocks.select { |b| b.type == "table" }
      table_rows   = if table_blocks.empty?
        {}
      else
        threads = table_blocks.map { |tb| [tb.id, Thread.new { fetch_all_children(tb.id) }] }
        threads.map { |id, t| [id, t.value] }.to_h
      end

      blocks_to_structs(blocks, table_rows: table_rows)
    end

    private

    attr_reader :client, :database_id

    def fetch_all_children(block_id)
      children = []
      cursor   = nil
      loop do
        params = { block_id: block_id, page_size: 100 }
        params[:start_cursor] = cursor if cursor
        response = @client.block_children(**params)
        children.concat(response.results)
        break unless response.has_more
        cursor = response.next_cursor
      end
      children
    end

    def fetch_all_sprints
      sprints = []
      cursor  = nil
      loop do
        params = { database_id: @sprints_db_id, page_size: 100 }
        params[:start_cursor] = cursor if cursor
        response = @client.database_query(**params)
        response.results.each { |r| sprints << parse_sprint(r) }
        break unless response.has_more
        cursor = response.next_cursor
      end
      sprints.sort_by { |s| s[:dates]&.dig("start") || "" }.reverse
    end

    def parse_sprint(result)
      {
        id:     result.id,
        name:   result.properties.dig("Sprint name", "title")&.first&.dig("plain_text") || "Unknown",
        status: result.properties.dig("Sprint status", "status", "name"),
        dates:  result.properties.dig("Dates", "date"),
      }
    end

    HEADING_TYPES = %w[heading_1 heading_2 heading_3].freeze
    SPACED_TYPES  = (HEADING_TYPES + %w[callout]).freeze

    def blocks_to_structs(blocks, table_rows:)
      structs      = []
      list_counter = 0
      prev_type    = nil

      blocks.each do |block|
        list_counter = 0 if block.type != "numbered_list_item" && prev_type == "numbered_list_item"
        list_counter += 1 if block.type == "numbered_list_item"

        structs << { type: :empty } if !structs.empty? && (SPACED_TYPES.include?(block.type) || SPACED_TYPES.include?(prev_type))

        result = block_to_struct(block, list_num: list_counter, table_rows: table_rows)
        case result
        when Array then structs.concat(result)
        when Hash  then structs << result
        end
        prev_type = block.type
      end

      structs
    end

    def block_to_struct(block, list_num: 1, table_rows:)
      case block.type
      when "paragraph"
        { type: :paragraph, runs: rich_text_to_runs(block.paragraph.rich_text) }
      when "heading_1"
        { type: :heading_1, runs: rich_text_to_runs(block.heading_1.rich_text) }
      when "heading_2"
        { type: :heading_2, runs: rich_text_to_runs(block.heading_2.rich_text) }
      when "heading_3"
        { type: :heading_3, runs: rich_text_to_runs(block.heading_3.rich_text) }
      when "bulleted_list_item"
        { type: :bulleted_list, runs: rich_text_to_runs(block.bulleted_list_item.rich_text) }
      when "numbered_list_item"
        { type: :numbered_list, list_num: list_num, runs: rich_text_to_runs(block.numbered_list_item.rich_text) }
      when "to_do"
        { type: :todo, checked: block.to_do.checked || false, runs: rich_text_to_runs(block.to_do.rich_text) }
      when "code"
        lang = block.code&.language || ""
        all_text = block.code.rich_text.map(&:plain_text).join
        lines = all_text.split("\n")
        [{ type: :code_fence, lang: lang, opening: true }] +
          lines.map { |l| { type: :code_line, runs: [plain_run(l)] } } +
          [{ type: :code_fence, lang: nil, opening: false }]
      when "divider"
        { type: :divider, runs: [] }
      when "image"
        { type: :media, runs: [plain_run("🖼  Image")] }
      when "video"
        { type: :media, runs: [plain_run("🎬  Video")] }
      when "file"
        { type: :media, runs: [plain_run("📎  File")] }
      when "pdf"
        { type: :media, runs: [plain_run("📄  PDF")] }
      when "bookmark"
        { type: :media, runs: [plain_run("🔗  #{block.bookmark&.url || ''}")] }
      when "embed"
        { type: :media, runs: [plain_run("📦  Embed")] }
      when "callout"
        icon  = block.callout&.icon&.emoji || "💡"
        color = block.callout&.color
        runs  = rich_text_to_runs(block.callout.rich_text)
        [
          { type: :callout_open,  icon: icon, color: color },
          { type: :callout_body,  runs: runs, color: color },
          { type: :callout_close, color: color },
        ]
      when "quote"
        { type: :quote, runs: rich_text_to_runs(block.quote.rich_text) }
      when "toggle"
        { type: :toggle, runs: rich_text_to_runs(block.toggle.rich_text) }
      when "table_of_contents"
        { type: :media, runs: [plain_run("📑  Table of Contents")] }
      when "child_page"
        { type: :media, runs: [plain_run("📄  #{block.child_page&.title || 'Page'}")] }
      when "child_database"
        { type: :media, runs: [plain_run("🗃  Database")] }
      when "table"
        rows       = table_rows[block.id] || []
        has_header = block.table&.has_row_header || false
        parsed     = rows.map do |row|
          (row.table_row&.cells || []).map { |cell| cell.map(&:plain_text).join }
        end
        result = []
        parsed.each_with_index do |cells, i|
          result << { type: :table_row, cells: cells, header: has_header && i == 0 }
          result << { type: :table_sep } if has_header && i == 0
        end
        result
      end
    rescue StandardError
      { type: :error, runs: [plain_run("[⚠ Error: #{block.type}]")] }
    end

    def rich_text_to_runs(rich_text)
      return [] unless rich_text
      rich_text.map do |t|
        ann   = t.annotations
        color = ann&.color
        color = nil if color.nil? || color == "default"
        {
          text:          t.plain_text || "",
          bold:          ann&.bold          || false,
          italic:        ann&.italic        || false,
          code:          ann&.code          || false,
          strikethrough: ann&.strikethrough || false,
          color:         color,
        }
      end
    end

    def plain_run(text)
      { text: text, bold: false, italic: false, code: false, strikethrough: false, color: nil }
    end
  end
end
