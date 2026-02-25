# frozen_string_literal: true

module Nox
  class Board
    attr_reader :all_tasks, :filtered_tasks, :current_row, :search_query

    def initialize(tasks)
      @all_tasks      = sort_by_updated_desc(tasks.reject(&:sub_task?))
      @filtered_tasks = @all_tasks
      @current_row    = 0
      @search_query   = ""
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

    def move_to(idx)
      max_row = [filtered_tasks.length - 1, 0].max
      @current_row = [[idx, 0].max, max_row].min
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
      @all_tasks = sort_by_updated_desc(tasks.reject(&:sub_task?))
      search(@search_query)
    end

    def all_owners
      @all_tasks.flat_map(&:owner_names).uniq.sort
    end

    def tasks_count_by_owner
      counts = Hash.new(0)
      @all_tasks.each { |t| t.owner_names.each { |name| counts[name] += 1 } }
      counts
    end

    def filter_by_owner(owner)
      if owner.nil?
        @filtered_tasks = @all_tasks
      else
        @filtered_tasks = @all_tasks.select { |t| t.owner_names.include?(owner) }
      end
      @current_row = 0
    end

    private

    def sort_by_updated_desc(tasks)
      tasks.sort_by { |t| t.updated_at || "" }.reverse
    end
  end
end
