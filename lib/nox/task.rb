# frozen_string_literal: true

module Nox
  class Task
    attr_reader :id, :title, :status, :priority, :owners, :url, :completion_time, :updated_at,
                :parent_id, :sub_item_ids, :points, :domains, :type, :created_at
    attr_writer :owners, :status

    def initialize(id:, title:, status:, priority:, owners:, url:, completion_time:, updated_at:,
                   parent_id: nil, sub_item_ids: [], points: nil, domains: [], type: nil, created_at: nil)
      @id = id
      @title = title
      @status = status
      @priority = priority
      @owners = owners || []
      @url = url
      @completion_time = completion_time
      @updated_at = updated_at
      @parent_id = parent_id
      @sub_item_ids = sub_item_ids || []
      @points = points
      @domains = domains || []
      @type = type
      @created_at = created_at
    end

    def self.from_notion(page)
      props = page.properties

      title = extract_title(props)
      status = props.dig("Status", "status", "name") || "Unknown"
      priority = props.dig("Priority", "select", "name")
      owner_people = props.dig("owner", "people") || []
      owners = owner_people.map { |p| { id: p["id"], name: p["name"] } }
      completion_time = props.dig("Completion Time", "date", "start")
      parent_rel = props.dig("Parent-task", "relation") || []
      sub_rel    = props.dig("Sub-tasks", "relation") || []

      # Fields used by the assignment roulette (Nox::Roulette).
      points  = props.dig("預估點數", "number")
      domains = (props.dig("Fault Domain", "multi_select") || []).map { |o| o["name"] }
      type    = props.dig("類型", "select", "name")
      created = props.dig("Created time", "created_time")

      new(
        id: page.id,
        title: title,
        status: status,
        priority: priority,
        owners: owners,
        url: page.url,
        completion_time: completion_time,
        updated_at: page.last_edited_time,
        parent_id: parent_rel.first&.dig("id"),
        sub_item_ids: sub_rel.map { |r| r["id"] },
        points: points,
        domains: domains,
        type: type,
        created_at: created
      )
    end

    def has_sub_tasks?
      !@sub_item_ids.empty?
    end

    def sub_task?
      !@parent_id.nil?
    end

    # Display string: comma-joined owner names, or nil if none
    def assignee
      names = owner_names
      names.empty? ? nil : names.join(", ")
    end

    def owner_names
      @owners.map { |o| o[:name] }.compact
    end

    def owner_ids
      @owners.map { |o| o[:id] }.compact
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
