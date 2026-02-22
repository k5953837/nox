# frozen_string_literal: true

require "time"
require "unicode/display_width"

module Nox
  class Renderer
    STATUS_EMOJI = {
      "Done" => "✅",
      "In Progress" => "🟠",
      "In Development" => "🔵",
      "PR Reviewing" => "🟡",
      "PM Retest" => "🩷",
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

    PRIORITY_DOTS = {
      "Urgent" => "🔴",
      "High" => "🔴",
      "Medium" => "🟠",
      "P1" => "🔴",
      "P2" => "🟡",
      "P3" => "🔵"
    }.freeze

    STATUS_TEXT = {
      "Done" => "Done ✓",
      "In Progress" => "In Progress",
      "In Development" => "In Dev",
      "PR Reviewing" => "In Review",
      "PM Retest" => "Retest",
      "Pending" => "Pending",
      "Not started" => ""
    }.freeze

    def initialize
      @pastel = Pastel.new
      @cursor = TTY::Cursor
    end

    def render(board, sprint_name: nil, status_message: nil, search_mode: false)
      width = TTY::Screen.width
      height = TTY::Screen.height
      buffer = []
      row = 1
      
      # Row 1: Header (絕對定位)
      left = " 🌙 #{@pastel.bold.cyan('nox')}"
      left += "  #{@pastel.yellow(sprint_name)}" if sprint_name
      right = "#{board.filtered_tasks.length}/#{board.all_tasks.length} tasks "
      padding = width - display_width(left) - display_width(right)
      header = "#{left}#{' ' * [padding, 1].max}#{@pastel.dim(right)}"
      buffer << "\e[#{row};1H#{header}\e[K"
      row += 1
      
      # Row 2: Divider
      buffer << "\e[#{row};1H#{"─" * width}\e[K"
      row += 1
      
      # Tasks area
      tasks = board.filtered_tasks
      max_lines = height - 4
      board.update_scroll(max_lines)
      task_offset = board.scroll_offset
      
      if tasks.empty?
        buffer << "\e[#{row};1H#{@pastel.dim('  (no matches)')}\e[K"
        row += 1
        (max_lines - 1).times do
          buffer << "\e[#{row};1H\e[K"
          row += 1
        end
      else
        visible_tasks = tasks[task_offset, max_lines] || []
        visible_tasks.each_with_index do |task, idx|
          actual_idx = task_offset + idx
          is_selected = actual_idx == board.current_row
          prefix = is_selected ? "▸ " : "  "
          dot = format_priority_dot(task.priority)
          assignee = task.assignee || ""
          
          updated = format_updated_time(task.updated_at)
          right_part = "#{updated}  #{assignee}"
          max_title_width = width - display_width(right_part) - 10
          title = truncate(task.title, max_title_width)
          
          left_part = "#{prefix}#{dot} #{title}"
          pad = width - display_width(left_part) - display_width(right_part) - 2
          
          if is_selected
            line = "#{left_part}#{' ' * [pad, 1].max}#{right_part}"
            buffer << "\e[#{row};1H#{@pastel.black.on_cyan(pad_line(line, width - 1))}\e[K"
          else
            line = "#{left_part}#{' ' * [pad, 1].max}#{@pastel.dim(right_part)}"
            buffer << "\e[#{row};1H#{line}\e[K"
          end
          row += 1
        end
        # 填滿剩餘空間
        (max_lines - visible_tasks.length).times do
          buffer << "\e[#{row};1H\e[K"
          row += 1
        end
      end
      
      # Footer (最後一行)
      footer_row = height
      if search_mode
        query = board.search_query
        footer = " /#{query}#{@pastel.cyan('_')}"
      else
        text = status_message || "j/k: move │ Enter: detail │ /: search │ @: owner │ s: sprint │ r: refresh │ q: quit"
        footer = @pastel.dim(" #{text}")
      end
      buffer << "\e[#{footer_row};1H#{footer}\e[K"
      
      # Atomic output
      $stdout.print buffer.join
      $stdout.flush
    end

    def render_task_detail(task, content_lines: [], scroll: 0)
      print @cursor.clear_screen
      print @cursor.move_to(0, 0)

      width = TTY::Screen.width
      height = TTY::Screen.height
      
      puts
      puts "  #{@pastel.bold(task.title)}"
      puts
      puts "  #{@pastel.dim('Status:')}    #{status_badge(task.status)}"
      puts "  #{@pastel.dim('Priority:')}  #{priority_badge(task.priority)}"
      puts "  #{@pastel.dim('Assignee:')}  #{assignee_badge(task.assignee)}"
      puts "  #{@pastel.dim('Completed:')} #{task.completion_time || '—'}" if task.done?
      puts
      puts "─" * width
      
      # Content area
      max_content_lines = height - 10
      
      if content_lines.empty?
        puts @pastel.dim("  Loading...")
        (max_content_lines - 1).times { puts }
      else
        visible = content_lines[scroll, max_content_lines] || []
        visible.each do |line|
          puts "  #{truncate(line, width - 4)}"
        end
        (max_content_lines - visible.length).times { puts }
      end
      
      puts "─" * width
      
      # Footer
      puts "  #{@pastel.dim(task.url)}"
      puts @pastel.dim("  j/k: scroll │ Space/b: page │ g/G: top/bottom │ ESC: back │ o: open")
    end

    def render_sprint_menu(sprints, selected_idx, current_sprint, search_query, width, height)
      print @cursor.clear_screen
      print @cursor.move_to(0, 0)
      
      puts
      puts "  #{@pastel.bold('Select Sprint')}"
      puts "  Search: #{search_query}#{@pastel.cyan('_')}"
      puts "  #{@pastel.dim('─' * 40)}"
      puts
      
      if sprints.empty?
        puts @pastel.dim("  (no matching sprints)")
      else
        max_visible = height - 10
        sprints.each_with_index do |sprint, idx|
          break if idx >= max_visible
          
          is_current = sprint[:id] == current_sprint[:id]
          is_selected = idx == selected_idx
          status_indicator = is_current ? "●" : " "
          dates = sprint[:dates] ? "#{sprint[:dates]['start']} ~ #{sprint[:dates]['end']}" : ""
          
          prefix = is_selected ? "▸ " : "  "
          
          if is_selected
            line = "#{prefix}#{status_indicator} #{sprint[:name]}  #{dates}"
            puts @pastel.black.on_cyan(pad_line(line, width - 2))
          else
            indicator = is_current ? @pastel.green(status_indicator) : status_indicator
            puts "#{prefix}#{indicator} #{sprint[:name]}  #{@pastel.dim(dates)}"
          end
        end
      end
      
      puts
      puts "  #{@pastel.dim('─' * 40)}"
      puts @pastel.dim("  Type to search │ j/k: move │ Enter: select │ Esc: cancel")
    end

    def render_owner_menu(owners, counts, selected_idx, width, height)
      print @cursor.clear_screen
      print @cursor.move_to(0, 0)
      
      puts
      puts "  #{@pastel.bold('Filter by Owner')}"
      puts "  #{@pastel.dim('─' * 30)}"
      puts
      
      # (all) 選項
      if selected_idx == 0
        puts @pastel.inverse("  ▸ (all)                      ")
      else
        puts "    (all)"
      end
      
      owners.each_with_index do |owner, idx|
        count = counts[owner] || 0
        line = "#{owner} (#{count})"
        if idx + 1 == selected_idx
          puts @pastel.inverse("  ▸ #{line.ljust(28)}")
        else
          puts "    #{line}"
        end
      end
      
      puts
      puts "  #{@pastel.dim('─' * 30)}"
      puts @pastel.dim("  j/k: move │ Enter: select │ Esc: cancel")
    end

    private

    def render_header(board, width, sprint_name = nil)
      left = " 🌙 #{@pastel.bold.cyan('nox')}"
      left += "  #{@pastel.yellow(sprint_name)}" if sprint_name
      right = "#{board.tasks.length} tasks "
      padding = width - display_width(left) - display_width(right)
      "\n#{left}#{' ' * [padding, 1].max}#{@pastel.dim(right)}"
    end

    def render_status_tabs(board, width)
      current_status = board.visible_statuses[board.current_col]
      count = board.current_column_tasks.length
      
      col_idx = board.current_col + 1
      total_cols = board.visible_statuses.length
      
      left_arrow = board.current_col > 0 ? "◀ " : "  "
      right_arrow = board.current_col < total_cols - 1 ? " ▶" : "  "
      
      center = "#{current_status} (#{count})"
      nav = "[#{col_idx}/#{total_cols}]"
      
      " #{left_arrow}#{@pastel.bold(center)}#{right_arrow}  #{@pastel.dim(nav)}"
    end

    def render_tasks(board, width, max_lines)
      tasks = board.current_column_tasks
      
      if tasks.empty?
        puts @pastel.dim("  (no tasks)")
        (max_lines - 1).times { puts }
        return
      end

      lines_printed = 0
      tasks.each_with_index do |task, idx|
        break if idx >= max_lines
        
        is_selected = idx == board.current_row
        prefix = is_selected ? "▸ " : "  "
        dot = format_priority_dot(task.priority)
        right_text = task.assignee || ""
        
        max_title_width = width - 25
        title = truncate(task.title, max_title_width)
        
        left = "#{prefix}#{dot} #{title}"
        right = right_text
        padding = width - display_width(left) - display_width(right) - 2
        
        line = "#{left}#{' ' * [padding, 1].max}#{right}"
        
        if is_selected
          puts @pastel.black.on_cyan(pad_line(line, width))
        else
          puts "#{left}#{' ' * [padding, 1].max}#{@pastel.dim(right)}"
        end
        lines_printed += 1
      end
      
      # 填滿剩餘空間
      (max_lines - lines_printed).times { puts }
    end

    def render_footer(message, width, search_mode: false)
      if search_mode
        text = message || "Type to search │ j/k: move │ Enter: confirm │ Esc: cancel"
      else
        text = message || "h/l: status │ j/k: move │ Enter: detail │ /: search │ @: owner │ s: sprint │ r: refresh │ q: quit"
      end
      @pastel.dim(" #{text}")
    end

    def format_priority(priority)
      return @pastel.dim("[—]") unless priority
      
      short = priority[0]
      color = PRIORITY_COLORS.find { |k, _| priority.include?(k) }&.last
      text = "[#{short}]"
      color ? @pastel.send(color, text) : text
    end

    def format_priority_dot(priority)
      PRIORITY_DOTS[priority] || "⚪"
    end

    def colorize_priority(text)
      return @pastel.dim("—") unless text && text != "—"
      
      color = PRIORITY_COLORS.find { |k, _| text.include?(k) }&.last
      color ? @pastel.send(color, text) : text
    end

    def status_badge(status)
      return @pastel.dim("—") unless status
      
      case status
      when "Done"
        @pastel.black.on_green(" ✓ Done ")
      when "In Progress"
        @pastel.black.on_yellow(" In Progress ")
      when "In Development"
        @pastel.white.on_blue(" In Dev ")
      when "PR Reviewing"
        @pastel.black.on_yellow(" In Review ")
      when "PM Retest"
        @pastel.black.on_magenta(" Retest ")
      when "Pending"
        @pastel.white.on_bright_black(" Pending ")
      when "Not started"
        @pastel.white.on_bright_black(" Not Started ")
      else
        @pastel.white.on_bright_black(" #{status} ")
      end
    end

    def priority_badge(priority)
      return @pastel.dim("—") unless priority
      
      case priority
      when "Urgent", "High", "P1"
        @pastel.white.on_red(" #{priority} ")
      when "Medium", "P2"
        @pastel.black.on_yellow(" #{priority} ")
      when "Low", "P3"
        @pastel.black.on_green(" #{priority} ")
      else
        @pastel.white.on_bright_black(" #{priority} ")
      end
    end

    def assignee_badge(assignee)
      return @pastel.dim("—") unless assignee
      
      @pastel.white.on_cyan(" #{assignee} ")
    end

    def to_initials(name)
      return "" unless name
      
      parts = name.split(/\s+/)
      if parts.length >= 2
        # "Johnson Lu" -> "JL"
        parts.map { |p| p[0] }.join.upcase
      else
        # "Johnson" -> "Jo" or single char names
        name.length > 2 ? name[0..1].capitalize : name.upcase
      end
    end

    def truncate(str, max_width)
      return str if display_width(str) <= max_width
      
      result = ""
      str.each_char do |char|
        break if display_width(result + char + "...") > max_width
        result += char
      end
      result + "..."
    end

    def display_width(str)
      Unicode::DisplayWidth.of(str.gsub(/\e\[[0-9;]*m/, ""))
    end

    def pad_line(str, width)
      current = display_width(str)
      padding = width - current - 1
      str + (" " * [padding, 0].max)
    end

    def format_updated_time(time_str)
      return "" unless time_str
      time = Time.parse(time_str).localtime
      now = Time.now
      diff = now - time
      
      if diff < 0
        "just now"
      elsif diff < 60
        "just now"
      elsif diff < 3600
        "#{(diff / 60).to_i}m ago"
      elsif diff < 86400
        "#{(diff / 3600).to_i}h ago"
      elsif diff < 86400 * 7
        "#{(diff / 86400).to_i}d ago"
      else
        time.strftime("%m/%d")
      end
    rescue => e
      ""
    end
  end
end
