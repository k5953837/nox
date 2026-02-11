# frozen_string_literal: true

module Nox
  class Client
    def initialize
      @client = Notion::Client.new(token: ENV.fetch("NOTION_TOKEN"))
      @database_id = ENV.fetch("NOTION_DATABASE_ID")
    end

    def fetch_tasks
      tasks = []
      @client.database_query(database_id: @database_id) do |page|
        page.results.each do |result|
          tasks << Task.from_notion(result)
        end
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

    private

    attr_reader :client, :database_id
  end
end
