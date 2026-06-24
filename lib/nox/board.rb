# frozen_string_literal: true

require "set"

module Nox
  class Board
    attr_reader :all_tasks, :filtered_tasks, :current_row, :search_query, :status_filter, :every_task

    def initialize(tasks)
      ingest(tasks)
      @owner_filter  = nil
      @status_filter = Set.new
      @search_query  = ""
      @current_row   = 0
      apply_filters
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
      apply_filters
    end

    def filter_by_owner(owner)
      @owner_filter = owner
      apply_filters
    end

    def filter_by_statuses(statuses)
      @status_filter = statuses.is_a?(Set) ? statuses : Set.new(statuses)
      apply_filters
    end

    def refresh(tasks)
      ingest(tasks)
      apply_filters
    end

    # Owners across every task (incl. sub-tasks) so someone whose only work is
    # sub-tasks still appears and can be selected.
    def all_owners
      @every_task.flat_map(&:owner_names).uniq.sort
    end

    def tasks_count_by_owner
      counts = Hash.new(0)
      @every_task.each { |t| t.owner_names.each { |name| counts[name] += 1 } }
      counts
    end

    # Tasks matching owner + search but NOT the status filter. Drives the
    # status-filter popup counts and the header chips, so narrowing to one
    # status doesn't zero out the other chips.
    def owner_scoped_tasks
      candidate_pool.select { |t| match_owner?(t) && match_search?(t) }
    end

    def status_counts
      counts = Hash.new(0)
      owner_scoped_tasks.each { |t| counts[t.status] += 1 }
      counts
    end

    private

    # Sub-tasks only surface when a specific owner is selected — the "(all)"
    # view stays root-only so it isn't flooded with child rows.
    def candidate_pool
      @owner_filter ? @every_task : @all_tasks
    end

    def ingest(tasks)
      @every_task = sort_by_updated_desc(tasks)
      @all_tasks  = @every_task.reject(&:sub_task?)
    end

    def apply_filters
      @filtered_tasks = candidate_pool.select do |t|
        match_owner?(t) && match_status?(t) && match_search?(t)
      end
      @current_row = 0
    end

    def match_owner?(task)
      @owner_filter.nil? || task.owner_names.include?(@owner_filter)
    end

    def match_status?(task)
      @status_filter.empty? || @status_filter.include?(task.status)
    end

    def match_search?(task)
      return true if @search_query.empty?
      q = @search_query.downcase
      task.title.downcase.include?(q) ||
        task.assignee&.downcase&.include?(q) ||
        task.priority&.downcase&.include?(q) ||
        task.status&.downcase&.include?(q)
    end

    def sort_by_updated_desc(tasks)
      tasks.sort_by { |t| t.updated_at || "" }.reverse
    end
  end
end
