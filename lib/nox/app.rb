# frozen_string_literal: true

module Nox
  class App
    def initialize
      @client = Client.new
      @renderer = Renderer.new
      @reader = TTY::Reader.new(interrupt: :exit)
      @cursor = TTY::Cursor
      @running = false
      @mode = :board
      @search_query = nil
      @status_message = nil
      @owner_menu_idx = 0
      @sprint_menu_idx = 0
      @sprint_search_query = ""
      @current_sprint = nil
      @sprints = []
      @search_mode = false
      @task_content = nil
      @detail_scroll = 0
      @content_lines = []
    end

    def run
      @running = true
      print "🌙 Loading sprint..."
      @current_sprint = @client.fetch_current_sprint
      unless @current_sprint
        puts "\rNo current sprint found!"
        return
      end
      
      print "\r🌙 Loading tasks...  "
      tasks = @client.fetch_tasks_by_sprint(@current_sprint[:id])
      print "\r                      \r"
      @board = Board.new(tasks)
      
      print "\e[?1049h"  # 進入 alternate screen
      print "\e[2J\e[H"  # 清除螢幕 + 移到左上角
      print @cursor.hide
      $stdout.flush
      
      trap("INT") { quit }
      trap("TERM") { quit }
      
      main_loop
    ensure
      print @cursor.show
      print "\e[?1049l"  # 退出 alternate screen
    end

    private

    def main_loop
      while @running
        case @mode
        when :board
          render_board
          handle_board_input
        when :detail
          render_detail
          handle_detail_input
        when :owner_menu
          render_owner_menu
          handle_owner_menu_input
        when :sprint_menu
          render_sprint_menu
          handle_sprint_menu_input
        end
      end
    end

    def render_board
      sprint_name = @current_sprint ? @current_sprint[:name] : nil
      @renderer.render(@board, sprint_name: sprint_name, status_message: @status_message, search_mode: @search_mode)
      @status_message = nil
    end

    def render_detail
      task = @board.current_task
      return enter_board_mode unless task
      
      @renderer.render_task_detail(task, content_lines: @content_lines, scroll: @detail_scroll)
    end

    def handle_board_input
      key = @reader.read_keypress
      
      case key
      when "q", "\u0003" # q or Ctrl+C
        quit
      when "j", "\e[B" # j or down arrow
        @board.move_down
      when "k", "\e[A" # k or up arrow
        @board.move_up
      when "\r", "\n" # Enter
        enter_detail_mode if @board.current_task
      when "\u007F", "\b" # Backspace
        if @search_mode
          query = @board.search_query[0..-2]
          @board.search(query)
        end
      when "@"
        enter_owner_menu
      when "s"
        enter_sprint_menu
      when "r"
        refresh
      when "o"
        open_in_browser
      when "/"
        @search_mode = true
      when "\e" # Esc - exit search mode
        @search_mode = false
        @board.search("")
      else
        # 打字即時搜尋 (只在 search mode)
        if @search_mode && key && key.match?(/[[:print:]]/)
          query = @board.search_query + key
          @board.search(query)
        end
      end
    end

    def handle_detail_input
      key = @reader.read_keypress
      max_scroll = [@content_lines.length - visible_content_lines, 0].max
      
      case key
      when "\e", "q" # ESC or q
        enter_board_mode
      when "j", "\e[B" # j or down
        @detail_scroll = [@detail_scroll + 1, max_scroll].min
      when "k", "\e[A" # k or up
        @detail_scroll = [@detail_scroll - 1, 0].max
      when " " # Space - page down
        @detail_scroll = [@detail_scroll + visible_content_lines, max_scroll].min
      when "b" # b - page up
        @detail_scroll = [@detail_scroll - visible_content_lines, 0].max
      when "g" # g - top
        @detail_scroll = 0
      when "G" # G - bottom
        @detail_scroll = max_scroll
      when "o"
        open_in_browser
      end
    end

    def visible_content_lines
      TTY::Screen.height - 10
    end

    def enter_board_mode
      @mode = :board
    end

    def enter_detail_mode
      task = @board.current_task
      return unless task
      
      @task_content = nil
      @content_lines = []
      @detail_scroll = 0
      @mode = :detail
      render_detail  # Show immediately with "loading"
      @task_content = @client.fetch_page_content(task.id)
      @content_lines = @task_content.split("\n")
    end

    def enter_owner_menu
      @owner_menu_idx = 0
      @mode = :owner_menu
    end

    def render_owner_menu
      owners = @board.all_owners
      counts = @board.tasks_count_by_owner
      width = TTY::Screen.width
      height = TTY::Screen.height
      @renderer.render_owner_menu(owners, counts, @owner_menu_idx, width, height)
    end

    def handle_owner_menu_input
      key = @reader.read_keypress
      owners = @board.all_owners
      max_idx = owners.length
      
      case key
      when "j", "\e[B"
        @owner_menu_idx = [@owner_menu_idx + 1, max_idx].min
      when "k", "\e[A"
        @owner_menu_idx = [@owner_menu_idx - 1, 0].max
      when "\r", "\n"
        if @owner_menu_idx == 0
          @board.filter_by_owner(nil)
          @status_message = "Showing all tasks"
        else
          owner = owners[@owner_menu_idx - 1]
          @board.filter_by_owner(owner)
          @status_message = "Filtered by: #{owner}"
        end
        @mode = :board
      when "\e", "q"
        @mode = :board
      end
    end

    def enter_sprint_menu
      @sprints = @client.fetch_sprints if @sprints.empty?
      @sprint_menu_idx = 0
      @sprint_search_query = ""
      @mode = :sprint_menu
    end

    def render_sprint_menu
      width = TTY::Screen.width
      height = TTY::Screen.height
      filtered = filter_sprints(@sprints, @sprint_search_query)
      @renderer.render_sprint_menu(filtered, @sprint_menu_idx, @current_sprint, @sprint_search_query, width, height)
    end

    def filter_sprints(sprints, query)
      return sprints if query.nil? || query.empty?
      sprints.select { |s| s[:name].downcase.include?(query.downcase) }
    end

    def handle_sprint_menu_input
      key = @reader.read_keypress
      filtered = filter_sprints(@sprints, @sprint_search_query)
      max_idx = [filtered.length - 1, 0].max
      
      case key
      when "j", "\e[B"
        @sprint_menu_idx = [@sprint_menu_idx + 1, max_idx].min
      when "k", "\e[A"
        @sprint_menu_idx = [@sprint_menu_idx - 1, 0].max
      when "\r", "\n"
        return if filtered.empty?
        selected = filtered[@sprint_menu_idx]
        if selected && selected[:id] != @current_sprint[:id]
          @current_sprint = selected
          @status_message = "Loading #{selected[:name]}..."
          @mode = :board
          render_board
          tasks = @client.fetch_tasks_by_sprint(selected[:id])
          @board = Board.new(tasks)
          @status_message = "Switched to: #{selected[:name]}"
        end
        @mode = :board
      when "\e"
        @mode = :board
      when "\u007F", "\b"  # Backspace
        @sprint_search_query = @sprint_search_query[0..-2]
        @sprint_menu_idx = 0
      else
        if key && key.match?(/[[:print:]]/)
          @sprint_search_query += key
          @sprint_menu_idx = 0
        end
      end
    end

    def refresh
      @status_message = "Refreshing..."
      render_board
      tasks = @client.fetch_tasks_by_sprint(@current_sprint[:id])
      @board.refresh(tasks)
      @status_message = "Refreshed! #{tasks.length} tasks loaded"
    end

    def open_in_browser
      task = @board.current_task
      return unless task
      
      system("open", task.url)
      @status_message = "Opened in browser"
    end

    def quit
      @running = false
    end
  end
end
