# frozen_string_literal: true

module Nox
  class Board
    STATUSES = [
      "Not started",
      "In Progress",
      "In Development",
      "PR Reviewing",
      "PM Retest",
      "Done"
    ].freeze

    attr_reader :tasks, :columns, :current_col, :current_row

    def initialize(tasks)
      @tasks = tasks
      @columns = group_by_status(tasks)
      @current_col = 0
      @current_row = 0
    end

    def current_column_tasks
      status = visible_statuses[current_col]
      columns[status] || []
    end

    def current_task
      current_column_tasks[current_row]
    end

    def visible_statuses
      @visible_statuses ||= STATUSES.select { |s| columns[s]&.any? }
    end

    def move_left
      @current_col = [current_col - 1, 0].max
      @current_row = [current_row, current_column_tasks.length - 1].min.clamp(0, Float::INFINITY)
    end

    def move_right
      @current_col = [current_col + 1, visible_statuses.length - 1].min
      @current_row = [current_row, current_column_tasks.length - 1].min.clamp(0, Float::INFINITY)
    end

    def move_up
      @current_row = [current_row - 1, 0].max
    end

    def move_down
      max_row = [current_column_tasks.length - 1, 0].max
      @current_row = [current_row + 1, max_row].min
    end

    def refresh(tasks)
      @tasks = tasks
      @columns = group_by_status(tasks)
      @visible_statuses = nil
      @current_row = [current_row, current_column_tasks.length - 1].min.clamp(0, Float::INFINITY)
    end

    def filter(query)
      return if query.nil? || query.empty?

      filtered = tasks.select do |t|
        t.title.downcase.include?(query.downcase) ||
          t.assignee&.downcase&.include?(query.downcase) ||
          t.priority&.downcase&.include?(query.downcase)
      end
      @columns = group_by_status(filtered)
      @visible_statuses = nil
      @current_col = 0
      @current_row = 0
    end

    private

    def group_by_status(tasks)
      tasks.group_by(&:status)
    end
  end
end
