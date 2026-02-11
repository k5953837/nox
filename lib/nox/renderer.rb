# frozen_string_literal: true

module Nox
  class Renderer
    STATUS_EMOJI = {
      "Done" => "✅",
      "In Progress" => "🟠",
      "In Development" => "🔵",
      "PR Reviewing" => "🟡",
      "PM Retest" => "🩷",
      "In Diversity Testing" => "🔵",
      "Pending" => "⏸️",
      "Not started" => "⚪"
    }.freeze

    PRIORITY_COLORS = {
      "High" => :red,
      "Medium" => :yellow,
      "P1" => :red,
      "P2" => :yellow,
      "P3" => :green
    }.freeze

    def initialize
      @pastel = Pastel.new
      @cursor = TTY::Cursor
    end

    def render(board, status_message: nil)
      output = []
      output << @cursor.clear_screen
      output << @cursor.move_to(0, 0)
      output << render_header(board)
      output << render_columns(board)
      output << render_status_bar(board, status_message)
      print output.join
    end

    def render_task_detail(task)
      output = []
      output << @cursor.clear_screen
      output << @cursor.move_to(0, 0)

      box = TTY::Box.frame(
        width: TTY::Screen.width - 4,
        height: TTY::Screen.height - 4,
        padding: 1,
        title: { top_left: " #{task.display_title(60)} " },
        border: :round
      ) do
        lines = []
        lines << "#{@pastel.bold('Status:')} #{STATUS_EMOJI[task.status] || '⚪'} #{task.status}"
        lines << "#{@pastel.bold('Priority:')} #{colorize_priority(task.priority)}" if task.priority
        lines << "#{@pastel.bold('Assignee:')} #{task.assignee}" if task.assignee
        lines << "#{@pastel.bold('Completed:')} #{task.completion_time}" if task.completion_time
        lines << ""
        lines << @pastel.dim(task.url)
        lines.join("\n")
      end

      output << box
      output << "\n"
      output << @pastel.dim("  Press ESC to go back, o to open in browser")
      print output.join
    end

    private

    def render_header(board)
      title = @pastel.bold.cyan(" 🌙 nox ")
      task_count = "#{board.tasks.length} tasks"
      "\n#{title} #{@pastel.dim(task_count)}\n\n"
    end

    def render_columns(board)
      screen_width = TTY::Screen.width
      col_width = [screen_width / [board.visible_statuses.length, 1].max - 2, 30].max
      
      output = []
      
      # Header row
      headers = board.visible_statuses.map.with_index do |status, idx|
        emoji = STATUS_EMOJI[status] || "⚪"
        count = (board.columns[status] || []).length
        header = "#{emoji} #{status} (#{count})"
        if idx == board.current_col
          @pastel.inverse(header.ljust(col_width))
        else
          header.ljust(col_width)
        end
      end
      output << " #{headers.join(' │ ')}\n"
      output << " #{'─' * (screen_width - 2)}\n"
      
      # Task rows
      max_tasks = board.columns.values.map(&:length).max || 0
      max_visible = TTY::Screen.height - 10
      
      (0...[max_tasks, max_visible].min).each do |row|
        row_cells = board.visible_statuses.map.with_index do |status, col_idx|
          tasks = board.columns[status] || []
          task = tasks[row]
          
          if task
            cell = format_task_cell(task, col_width - 2)
            if col_idx == board.current_col && row == board.current_row
              @pastel.inverse(cell)
            else
              cell
            end
          else
            " " * (col_width - 2)
          end
        end
        output << " #{row_cells.join(' │ ')}\n"
      end
      
      output.join
    end

    def render_status_bar(board, message)
      width = TTY::Screen.width
      
      left = message || "h/l: columns │ j/k: tasks │ Enter: detail │ /: search │ r: refresh │ q: quit"
      left = @pastel.dim(left)
      
      task = board.current_task
      right = task ? @pastel.dim(task.assignee || "") : ""
      
      padding = width - visible_length(left) - visible_length(right) - 2
      padding = [padding, 1].max
      
      "\n #{left}#{' ' * padding}#{right}"
    end

    def format_task_cell(task, width)
      priority_indicator = task.priority ? "[#{task.priority[0]}]" : "   "
      priority_indicator = colorize_priority(priority_indicator)
      
      title_width = width - 5
      title = task.display_title(title_width)
      
      " #{priority_indicator} #{title.ljust(title_width)}"[0..width]
    end

    def colorize_priority(text)
      return @pastel.dim("—") unless text
      
      color = PRIORITY_COLORS.find { |k, _| text.include?(k) }&.last
      color ? @pastel.send(color, text) : text
    end

    def visible_length(str)
      str.gsub(/\e\[[0-9;]*m/, "").length
    end
  end
end
