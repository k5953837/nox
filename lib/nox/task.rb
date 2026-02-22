# frozen_string_literal: true

module Nox
  class Task
    attr_reader :id, :title, :status, :priority, :assignee, :url, :completion_time, :updated_at

    def initialize(id:, title:, status:, priority:, assignee:, url:, completion_time:, updated_at:)
      @id = id
      @title = title
      @status = status
      @priority = priority
      @assignee = assignee
      @url = url
      @completion_time = completion_time
      @updated_at = updated_at
    end

    def self.from_notion(page)
      props = page.properties

      title = extract_title(props)
      status = props.dig("Status", "status", "name") || "Unknown"
      priority = props.dig("Priority", "select", "name")
      assignee = props.dig("owner", "people")&.first&.dig("name")
      completion_time = props.dig("Completion Time", "date", "start")

      new(
        id: page.id,
        title: title,
        status: status,
        priority: priority,
        assignee: assignee,
        url: page.url,
        completion_time: completion_time,
        updated_at: page.last_edited_time
      )
    end

    def done?
      status == "Done"
    end

    def display_title(max_length = 40)
      if title.length > max_length
        "#{title[0..max_length - 3]}..."
      else
        title
      end
    end

    private

    def self.extract_title(props)
      title_prop = props["Items"] || props["Name"] || props["Title"] || props.values.find { |v| v["type"] == "title" }
      title_prop&.dig("title")&.map { |t| t["plain_text"] }&.join || "Untitled"
    end
  end
end
