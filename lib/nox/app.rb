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
    end

    def run
      @running = true
      tasks = @client.fetch_tasks
      @board = Board.new(tasks)
      
      print @cursor.hide
      
      trap("INT") { quit }
      trap("TERM") { quit }
      
      main_loop
    ensure
      print @cursor.show
      print @cursor.clear_screen
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
        when :search
          handle_search
        end
      end
    end

    def render_board
      @renderer.render(@board, status_message: @status_message)
      @status_message = nil
    end

    def render_detail
      task = @board.current_task
      return enter_board_mode unless task
      
      @renderer.render_task_detail(task)
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
      when "h", "\e[D" # h or left arrow
        @board.move_left
      when "l", "\e[C" # l or right arrow
        @board.move_right
      when "\r", "\n" # Enter
        enter_detail_mode if @board.current_task
      when "/"
        enter_search_mode
      when "r"
        refresh
      when "o"
        open_in_browser
      end
    end

    def handle_detail_input
      key = @reader.read_keypress
      
      case key
      when "\e", "q" # ESC or q
        enter_board_mode
      when "o"
        open_in_browser
      end
    end

    def handle_search
      print @cursor.clear_screen
      print @cursor.move_to(0, 0)
      print "\n 🔍 Search: "
      
      query = ""
      loop do
        key = @reader.read_keypress
        
        case key
        when "\e" # ESC
          @board.refresh(@client.fetch_tasks)
          @search_query = nil
          break
        when "\r", "\n" # Enter
          if query.empty?
            @board.refresh(@client.fetch_tasks)
          else
            @board.filter(query)
          end
          @search_query = query.empty? ? nil : query
          break
        when "\u007F", "\b" # Backspace
          query = query[0..-2]
          print "\r 🔍 Search: #{query}  "
          print "\r 🔍 Search: #{query}"
        else
          if key.match?(/[[:print:]]/)
            query += key
            print key
          end
        end
      end
      
      @mode = :board
    end

    def enter_board_mode
      @mode = :board
    end

    def enter_detail_mode
      @mode = :detail
    end

    def enter_search_mode
      @mode = :search
    end

    def refresh
      @status_message = "Refreshing..."
      render_board
      tasks = @client.fetch_tasks
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
