# frozen_string_literal: true

module Nox
  class Board
    attr_reader :all_tasks, :filtered_tasks, :current_row, :search_query, :scroll_offset

    def initialize(tasks)
      @all_tasks = sort_by_updated_desc(tasks)
      @filtered_tasks = @all_tasks
      @current_row = 0
      @search_query = ""
      @scroll_offset = 0
    end

    def update_scroll(visible_lines)
      if @current_row < @scroll_offset
        @scroll_offset = @current_row
      elsif @current_row >= @scroll_offset + visible_lines
        @scroll_offset = @current_row - visible_lines + 1
      end
    end

    def current_task
      filtered_tasks[current_row]
    end

    def move_up
      @current_row = [current_row - 1, 0].max
    end

    def move_down
      max_row = [filtered_tasks.length - 1, 0].max
      @current_row = [current_row + 1, max_row].min
    end

    def search(query)
      @search_query = query || ""
      
      if @search_query.empty?
        @filtered_tasks = @all_tasks
      else
        @filtered_tasks = @all_tasks.select do |t|
          t.title.downcase.include?(@search_query.downcase) ||
            t.assignee&.downcase&.include?(@search_query.downcase) ||
            t.priority&.downcase&.include?(@search_query.downcase) ||
            t.status&.downcase&.include?(@search_query.downcase)
        end
      end
      @current_row = 0
      @scroll_offset = 0
    end

    def refresh(tasks)
      @all_tasks = sort_by_updated_desc(tasks)
      search(@search_query)
    end

    def all_owners
      @all_tasks.map(&:assignee).compact.uniq.sort
    end

    def tasks_count_by_owner
      @all_tasks.group_by(&:assignee).transform_values(&:length)
    end

    def filter_by_owner(owner)
      if owner.nil?
        @filtered_tasks = @all_tasks
      else
        @filtered_tasks = @all_tasks.select { |t| t.assignee == owner }
      end
      @current_row = 0
    end

    private

    def sort_by_updated_desc(tasks)
      tasks.sort_by { |t| t.updated_at || "" }.reverse
    end
  end
end
