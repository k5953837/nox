# frozen_string_literal: true

module Nox
  class Client
    def initialize
      @client = Notion::Client.new(token: ENV.fetch("NOTION_TOKEN"))
      @database_id = ENV.fetch("NOTION_DATABASE_ID")
      @sprints_db_id = ENV.fetch("NOTION_SPRINTS_DB_ID")
    end

    def fetch_sprints
      sprints = []
      cursor = nil
      
      loop do
        params = { database_id: @sprints_db_id, page_size: 100 }
        params[:start_cursor] = cursor if cursor
        
        response = @client.database_query(**params)
        response.results.each do |result|
          sprints << {
            id: result.id,
            name: result.properties.dig("Sprint name", "title")&.first&.dig("plain_text") || "Unknown",
            status: result.properties.dig("Sprint status", "status", "name"),
            dates: result.properties.dig("Dates", "date")
          }
        end
        break unless response.has_more
        cursor = response.next_cursor
      end
      
      sprints.sort_by { |s| s[:dates]&.dig("start") || "" }.reverse
    end

    def fetch_current_sprint
      response = @client.database_query(
        database_id: @sprints_db_id,
        filter: { property: "Sprint status", status: { equals: "Current" } },
        page_size: 1
      )
      
      result = response.results.first
      return nil unless result
      
      {
        id: result.id,
        name: result.properties.dig("Sprint name", "title")&.first&.dig("plain_text") || "Unknown",
        status: result.properties.dig("Sprint status", "status", "name"),
        dates: result.properties.dig("Dates", "date")
      }
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

    def update_task_status(task_id, new_status)
      @client.update_page(
        page_id: task_id,
        properties: {
          "Status" => { status: { name: new_status } }
        }
      )
    end

    def fetch_page_content(page_id)
      blocks = []
      cursor = nil
      
      loop do
        params = { block_id: page_id, page_size: 100 }
        params[:start_cursor] = cursor if cursor
        
        response = @client.block_children(**params)
        blocks.concat(response.results)
        break unless response.has_more
        cursor = response.next_cursor
      end
      
      blocks_to_text(blocks)
    end

    private

    attr_reader :client, :database_id

    def blocks_to_text(blocks)
      lines = []
      list_counter = 0
      prev_type = nil
      
      blocks.each do |block|
        # Reset counter when leaving a numbered list
        if block.type != "numbered_list_item" && prev_type == "numbered_list_item"
          list_counter = 0
        end
        
        # Increment counter for numbered list items
        if block.type == "numbered_list_item"
          list_counter += 1
        end
        
        line = block_to_text(block, list_counter)
        lines << line if line
        prev_type = block.type
      end
      
      lines.join("\n")
    end

    def block_to_text(block, list_num = 1)
      case block.type
      when "paragraph"
        rich_text_to_plain(block.paragraph.rich_text)
      when "heading_1"
        "# " + rich_text_to_plain(block.heading_1.rich_text)
      when "heading_2"
        "## " + rich_text_to_plain(block.heading_2.rich_text)
      when "heading_3"
        "### " + rich_text_to_plain(block.heading_3.rich_text)
      when "bulleted_list_item"
        "• " + rich_text_to_plain(block.bulleted_list_item.rich_text)
      when "numbered_list_item"
        "#{list_num}. " + rich_text_to_plain(block.numbered_list_item.rich_text)
      when "to_do"
        checkbox = block.to_do.checked ? "☑" : "☐"
        "#{checkbox} " + rich_text_to_plain(block.to_do.rich_text)
      when "code"
        "```\n" + rich_text_to_plain(block.code.rich_text) + "\n```"
      when "divider"
        "───"
      when "image"
        "[🖼 Image]"
      when "video"
        "[🎬 Video]"
      when "file"
        "[📎 File]"
      when "pdf"
        "[📄 PDF]"
      when "bookmark"
        url = block.bookmark&.url || ""
        "[🔗 #{url}]"
      when "embed"
        "[📦 Embed]"
      when "callout"
        emoji = block.callout&.icon&.emoji || "💡"
        "#{emoji} " + rich_text_to_plain(block.callout.rich_text)
      when "quote"
        "> " + rich_text_to_plain(block.quote.rich_text)
      when "toggle"
        "▸ " + rich_text_to_plain(block.toggle.rich_text)
      when "table_of_contents"
        "[📑 Table of Contents]"
      when "child_page"
        "[📄 #{block.child_page&.title || 'Page'}]"
      when "child_database"
        "[🗃 Database]"
      else
        nil  # 未知 block type 就跳過
      end
    rescue => e
      "[⚠ Error: #{block.type}]"
    end

    def rich_text_to_plain(rich_text)
      return "" unless rich_text
      rich_text.map { |t| t.plain_text }.join
    end
  end
end
