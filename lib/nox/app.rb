# frozen_string_literal: true

module Nox
  SPINNER = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

  PRIORITY_DOTS = {
    "Urgent" => "🔴",
    "High"   => "🔴",
    "Medium" => "🟠",
    "P1"     => "🔴",
    "P2"     => "🟡",
    "P3"     => "🔵"
  }.freeze

  STATUS_SYMBOLS = {
    "Done"           => ["✓", :green],
    "In Progress"    => ["●", :yellow],
    "In Development" => ["●", :blue],
    "PR Reviewing"   => ["⟳", :yellow],
    "PM Retest"      => ["✦", :magenta],
    "Pending"        => ["⏸", :dark_gray],
    "Not started"    => ["○", :dark_gray],
  }.freeze

  class App
    def initialize
      @client              = Client.new
      @mode                = :loading
      @loading_message     = ""
      @loading_error       = nil
      @loading_tick        = 0
      @status_message      = nil
      @sprint_menu_idx     = 0
      @sprint_search_query = ""
      @current_sprint      = nil
      @sprints             = []
      @active_pane         = :tasks
      @search_mode         = false
      @detail_scroll       = 0
      @detail_height       = 20
      @content_lines       = []
    end

    def run
      RatatuiRuby.run do |tui|
        @tui = tui
        init_styles

        # ── Loading phase ──────────────────────────────────────────────────────
        loading("Finding current sprint...") do
          @current_sprint = @client.fetch_current_sprint
        end

        unless @current_sprint
          loading_error("No current sprint found. Press any key to exit.")
          @tui.poll_event
          next
        end

        loading("Loading tasks for #{@current_sprint[:name]}...") do
          tasks = @client.fetch_tasks_by_sprint(@current_sprint[:id])
          @board = Board.new(tasks)
          @list_state = RatatuiRuby::ListState.new(nil)
          @list_state.select(0) unless tasks.empty?
          @owner_list_state = RatatuiRuby::ListState.new(nil)
          @owner_list_state.select(0)
        end

        # ── Main loop ──────────────────────────────────────────────────────────
        @mode = :board
        loop do
          tui.draw { |frame| render(frame) }
          break if handle_event(@tui.poll_event) == :quit
        end
      end
    end

    private

    def init_styles
      @s_selected  = @tui.style(fg: :black, bg: :cyan, modifiers: [:bold])
      @s_dim       = @tui.style(fg: :dark_gray)
      @s_bold_cyan = @tui.style(fg: :cyan, modifiers: [:bold])
      @s_yellow    = @tui.style(fg: :yellow)
      @s_red       = @tui.style(fg: :red)
      @s_green     = @tui.style(fg: :green)
    end

    # ── Rendering ───────────────────────────────────────────────────────────────

    def render(frame)
      case @mode
      when :loading     then render_loading(frame)
      when :board       then render_board(frame)
      when :detail      then render_detail(frame)
      when :sprint_menu then render_sprint_menu(frame)
      end
    end

    def render_loading(frame)
      area = frame.area

      _, mid, _ = vsplit(area,
        @tui.constraint_fill(1),
        @tui.constraint_length(7),
        @tui.constraint_fill(1)
      )
      _, box_area, _ = @tui.layout_split(mid, direction: :horizontal, constraints: [
        @tui.constraint_fill(1),
        @tui.constraint_length(52),
        @tui.constraint_fill(1),
      ])

      if @loading_error
        border_style  = @tui.style(fg: :red)
        message_style = @tui.style(fg: :red)
        message       = @loading_error
        spinner_span  = @tui.text_span(content: "✗ ", style: message_style)
      else
        border_style  = @s_bold_cyan
        message_style = @s_dim
        message       = @loading_message
        spinner_span  = @tui.text_span(
          content: "#{SPINNER[@loading_tick % SPINNER.length]} ",
          style: @s_bold_cyan
        )
      end

      lines = [
        @tui.text_line(spans: [
          @tui.text_span(content: "🌙 "),
          @tui.text_span(content: "nox", style: @s_bold_cyan),
        ]),
        @tui.text_line(spans: []),
        @tui.text_line(spans: [
          spinner_span,
          @tui.text_span(content: message, style: message_style),
        ]),
      ]

      frame.render_widget(
        @tui.paragraph(
          text: lines,
          alignment: :center,
          block: @tui.block(borders: [:all], border_style:)
        ),
        box_area
      )
    end

    def render_board(frame)
      header_area, main_area, footer_area = vsplit(
        frame.area,
        @tui.constraint_length(2),
        @tui.constraint_fill(1),
        @tui.constraint_length(1)
      )

      # Header
      sprint_name = @current_sprint[:name]
      header_spans = [
        @tui.text_span(content: " 🌙 "),
        @tui.text_span(content: "nox", style: @s_bold_cyan),
        @tui.text_span(content: "  #{sprint_name}", style: @s_yellow),
      ]
      if @search_mode || !@board.search_query.empty?
        header_spans << @tui.text_span(content: "  🔍 #{@board.search_query}", style: @tui.style(fg: :magenta))
      end
      frame.render_widget(
        @tui.paragraph(
          text: @tui.text_line(spans: header_spans),
          block: @tui.block(borders: [:bottom])
        ),
        header_area
      )

      # Two-pane split — owner pane width fits longest label
      owner_width = owner_pane_width
      owner_area, task_area = @tui.layout_split(main_area,
        direction: :horizontal,
        constraints: [
          @tui.constraint_length(owner_width),
          @tui.constraint_fill(1),
        ]
      )

      render_owner_pane(frame, owner_area)
      render_task_pane(frame, task_area)

      # Footer — context-sensitive hints
      footer_text = if @search_mode
        "/#{@board.search_query}█  Esc: cancel  Backspace: delete"
      elsif @status_message
        @status_message
      elsif @active_pane == :owners
        "j/k: move  g/G: first/last  Tab/Enter: → tasks  s: sprint  r: refresh  q: quit"
      else
        "j/k: move  g/G: first/last  Enter: open  /: search  o: browser  Tab: → owners  s: sprint  r: refresh  q: quit"
      end
      @status_message = nil
      frame.render_widget(
        @tui.paragraph(text: footer_text, style: @s_dim),
        footer_area
      )
    end

    def render_owner_pane(frame, area)
      owners        = @board.all_owners
      counts        = @board.tasks_count_by_owner
      total         = @board.all_tasks.length
      active        = @active_pane == :owners
      border_style  = active ? @s_bold_cyan : @s_dim

      items = [
        @tui.text_line(spans: [
          @tui.text_span(content: "(all)"),
          @tui.text_span(content: "  (#{total})", style: @s_dim),
        ]),
        *owners.map { |o|
          @tui.text_line(spans: [
            @tui.text_span(content: o),
            @tui.text_span(content: "  (#{counts[o] || 0})", style: @s_dim),
          ])
        }
      ]

      frame.render_stateful_widget(
        @tui.list(
          items:,
          highlight_style: @s_selected,
          highlight_symbol: "▸ ",
          highlight_spacing: :always,
          block: @tui.block(
            title: " Owners ",
            borders: [:all],
            border_style:
          )
        ),
        area,
        @owner_list_state
      )
    end

    def render_task_pane(frame, area)
      tasks        = @board.filtered_tasks
      active       = @active_pane == :tasks
      border_style = active ? @s_bold_cyan : @s_dim

      selected_idx = @owner_list_state&.selected || 0
      active_owner = selected_idx == 0 ? nil : @board.all_owners[selected_idx - 1]
      title = if active_owner
        " #{active_owner} (#{tasks.length}) "
      else
        " Tasks (#{tasks.length}/#{@board.all_tasks.length}) "
      end

      if tasks.empty?
        frame.render_widget(
          @tui.paragraph(
            text: "  (no tasks)",
            style: @s_dim,
            block: @tui.block(title:, borders: [:all], border_style:)
          ),
          area
        )
        return
      end

      items = tasks.map do |task|
        dot            = PRIORITY_DOTS[task.priority] || "⚪"
        sym, sym_color = STATUS_SYMBOLS[task.status] || ["·", :dark_gray]
        updated        = format_time(task.updated_at)
        assignee       = task.assignee || ""
        @tui.text_line(spans: [
          @tui.text_span(content: "#{dot} #{task.title}  "),
          @tui.text_span(content: "#{sym}  ", style: @tui.style(fg: sym_color)),
          @tui.text_span(content: "#{updated}  #{assignee}", style: @s_dim),
        ])
      end

      frame.render_stateful_widget(
        @tui.list(
          items:,
          highlight_style: @s_selected,
          highlight_symbol: "▸ ",
          highlight_spacing: :always,
          block: @tui.block(title:, borders: [:all], border_style:)
        ),
        area,
        @list_state
      )

      sb_state = RatatuiRuby::ScrollbarState.new(tasks.length)
      sb_state.position = @list_state.offset
      sb_state.viewport_content_length = area.height - 2
      frame.render_stateful_widget(
        @tui.scrollbar(
          content_length: tasks.length,
          position: @list_state.offset || 0,
          orientation: :vertical_right,
          track_symbol: nil,
          thumb_symbol: "▐"
        ),
        area,
        sb_state
      )
    end

    def render_detail(frame)
      task = current_task
      unless task
        @mode = :board
        return
      end

      meta_height = task.done? ? 8 : 7
      meta_area, content_area, footer_area = vsplit(
        frame.area,
        @tui.constraint_length(meta_height),
        @tui.constraint_fill(1),
        @tui.constraint_length(1)
      )
      @detail_height = content_area.height

      meta_lines = [
        @tui.text_line(spans: [
          @tui.text_span(content: " Status:    "),
          @tui.text_span(content: task.status || "—", style: status_style(task.status))
        ]),
        @tui.text_line(spans: [
          @tui.text_span(content: " Priority:  "),
          @tui.text_span(content: task.priority || "—", style: priority_style(task.priority))
        ]),
        @tui.text_line(spans: [
          @tui.text_span(content: " Assignee:  "),
          @tui.text_span(content: task.assignee || "—")
        ]),
      ]
      if task.done?
        meta_lines << @tui.text_line(spans: [
          @tui.text_span(content: " Completed: "),
          @tui.text_span(content: task.completion_time || "—")
        ])
      end

      frame.render_widget(
        @tui.paragraph(
          text: meta_lines,
          block: @tui.block(
            title: " #{task.title} ",
            borders: [:all],
            border_style: @s_bold_cyan
          )
        ),
        meta_area
      )

      if @content_lines.empty?
        frame.render_widget(
          @tui.paragraph(text: "  Loading...", style: @s_dim),
          content_area
        )
      else
        visible = @content_lines[@detail_scroll, @detail_height] || []
        lines   = visible.map { |l| @tui.text_line(spans: [@tui.text_span(content: "  #{l}")]) }
        frame.render_widget(
          @tui.paragraph(text: lines, block: @tui.block(borders: [:bottom])),
          content_area
        )
      end

      total    = @content_lines.length
      position = total.zero? ? "" : " #{@detail_scroll + 1}-#{[@detail_scroll + @detail_height, total].min}/#{total}  "
      frame.render_widget(
        @tui.paragraph(
          text: @tui.text_line(spans: [
            @tui.text_span(content: " j/k: scroll  Space/b: page  g/G: top/bottom  o: open  Esc/q: back", style: @s_dim),
            @tui.text_span(content: position, style: @tui.style(fg: :cyan)),
          ])
        ),
        footer_area
      )
    end

    def render_sprint_menu(frame)
      filtered = filter_sprints(@sprints, @sprint_search_query)
      items    = filtered.map do |sprint|
        current  = sprint[:id] == @current_sprint[:id] ? "● " : "  "
        date_str = sprint_date_str(sprint)
        "#{current}#{sprint[:name]}#{date_str}"
      end

      menu_area = popup_area(frame.area, width: 64, height: [filtered.length + 4, 22].min)
      frame.render_widget(@tui.clear, menu_area)
      frame.render_widget(
        @tui.list(
          items: items.empty? ? ["(no matching sprints)"] : items,
          selected_index: @sprint_menu_idx,
          highlight_style: @s_selected,
          highlight_symbol: "▸ ",
          highlight_spacing: :always,
          block: @tui.block(
            title: " Select Sprint  /#{@sprint_search_query}█ ",
            borders: [:all],
            border_style: @s_bold_cyan
          )
        ),
        menu_area
      )
    end

    # ── Event Handling ──────────────────────────────────────────────────────────

    def handle_event(event)
      case @mode
      when :board       then handle_board_event(event)
      when :detail      then handle_detail_event(event)
      when :sprint_menu then handle_sprint_menu_event(event)
      end
    end

    def handle_board_event(event)
      case event
      in { type: :key, code: "q" } | { type: :key, code: "c", modifiers: ["ctrl"] }
        :quit

      # ── Pane switching ────────────────────────────────────────────────────────
      in { type: :key, code: "tab" } if !@search_mode
        @active_pane = (@active_pane == :owners) ? :tasks : :owners

      # ── Navigation ────────────────────────────────────────────────────────────
      in { type: :key, code: "j" | "down" }
        if @active_pane == :owners
          owner_move(:down)
        else
          @board.move_down
          @list_state.select(@board.current_row)
        end
      in { type: :key, code: "k" | "up" }
        if @active_pane == :owners
          owner_move(:up)
        else
          @board.move_up
          @list_state.select(@board.current_row)
        end
      in { type: :key, code: "g" }
        if @active_pane == :owners
          owner_jump(:first)
        else
          @board.move_to(0)
          @list_state.select(0)
        end
      in { type: :key, code: "G" }
        if @active_pane == :owners
          owner_jump(:last)
        else
          last = [@board.filtered_tasks.length - 1, 0].max
          @board.move_to(last)
          @list_state.select(last)
        end

      # ── Actions ───────────────────────────────────────────────────────────────
      in { type: :key, code: "enter" }
        if @active_pane == :owners
          @active_pane = :tasks  # Enter on owner → focus tasks pane
        else
          enter_detail_mode
        end
      in { type: :key, code: "o" }
        open_in_browser if @active_pane == :tasks

      # ── Search ────────────────────────────────────────────────────────────────
      in { type: :key, code: "/" }
        @search_mode  = true
        @active_pane  = :tasks
      in { type: :key, code: "esc" }
        @search_mode = false
        @board.search("")
        @list_state.select(0)
      in { type: :key, code: "backspace" }
        if @search_mode
          @board.search(@board.search_query[0..-2])
          @list_state.select(0)
        end
      in { type: :key, code: String => char } if @search_mode && char.length == 1 && char.match?(/[[:print:]]/)
        @board.search(@board.search_query + char)
        @list_state.select(0)

      # ── Global ────────────────────────────────────────────────────────────────
      in { type: :key, code: "s" }
        @sprints = @client.fetch_sprints if @sprints.empty?
        @sprint_menu_idx     = 0
        @sprint_search_query = ""
        @mode = :sprint_menu
      in { type: :key, code: "r" }
        refresh
      else
        nil
      end
    end

    def handle_detail_event(event)
      max_scroll = [@content_lines.length - @detail_height, 0].max
      page       = @detail_height

      case event
      in { type: :key, code: "esc" | "q" }
        @mode = :board
      in { type: :key, code: "j" | "down" }
        @detail_scroll = [@detail_scroll + 1, max_scroll].min
      in { type: :key, code: "k" | "up" }
        @detail_scroll = [@detail_scroll - 1, 0].max
      in { type: :key, code: " " }
        @detail_scroll = [@detail_scroll + page, max_scroll].min
      in { type: :key, code: "b" }
        @detail_scroll = [@detail_scroll - page, 0].max
      in { type: :key, code: "g" }
        @detail_scroll = 0
      in { type: :key, code: "g", modifiers: ["shift"] }
        @detail_scroll = max_scroll
      in { type: :key, code: "o" }
        open_in_browser
      else
        nil
      end
    end

    def handle_sprint_menu_event(event)
      filtered = filter_sprints(@sprints, @sprint_search_query)
      max_idx  = [filtered.length - 1, 0].max

      case event
      in { type: :key, code: "j" | "down" }
        @sprint_menu_idx = [@sprint_menu_idx + 1, max_idx].min
      in { type: :key, code: "k" | "up" }
        @sprint_menu_idx = [@sprint_menu_idx - 1, 0].max
      in { type: :key, code: "enter" }
        return if filtered.empty?
        selected = filtered[@sprint_menu_idx]
        if selected && selected[:id] != @current_sprint[:id]
          @current_sprint = selected
          loading("Loading #{selected[:name]}...") do
            tasks = @client.fetch_tasks_by_sprint(selected[:id])
            @board = Board.new(tasks)
            @list_state.select(0)
            @owner_list_state.select(0)
          end
          @status_message = "Switched to: #{selected[:name]}"
        end
        @mode = :board
      in { type: :key, code: "esc" }
        @mode = :board
      in { type: :key, code: "backspace" }
        @sprint_search_query = @sprint_search_query[0..-2]
        @sprint_menu_idx     = 0
      in { type: :key, code: String => char } if char.length == 1 && char.match?(/[[:print:]]/)
        @sprint_search_query += char
        @sprint_menu_idx     = 0
      else
        nil
      end
    end

    # ── Helpers ─────────────────────────────────────────────────────────────────

    def owner_move(direction)
      owners  = @board.all_owners
      max_idx = owners.length
      current = @owner_list_state.selected || 0
      new_idx = direction == :down ? [current + 1, max_idx].min : [current - 1, 0].max
      return if new_idx == current

      @owner_list_state.select(new_idx)
      owner = new_idx == 0 ? nil : owners[new_idx - 1]
      @board.filter_by_owner(owner)
      @list_state.select(0)
    end

    def owner_jump(position)
      owners  = @board.all_owners
      new_idx = position == :first ? 0 : owners.length
      @owner_list_state.select(new_idx)
      owner = new_idx == 0 ? nil : owners[new_idx - 1]
      @board.filter_by_owner(owner)
      @list_state.select(0)
    end

    def owner_pane_width
      owners = @board.all_owners
      counts = @board.tasks_count_by_owner
      labels = ["(all)  (#{@board.all_tasks.length})"] +
               owners.map { |o| "#{o}  (#{counts[o] || 0})" }
      max_label = labels.map(&:length).max || 8
      # +5 for borders (2) + highlight symbol "▸ " (2) + padding (1)
      [[max_label + 5, 18].max, 32].min
    end

    def sprint_date_str(sprint)
      dates = sprint[:dates]
      return "" unless dates
      start_date = dates["start"] || dates[:start]
      end_date   = dates["end"]   || dates[:end]
      return "" unless start_date
      parts = [start_date, end_date].compact.map { |d| d[5..9] }  # MM-DD
      "  #{parts.join(" → ")}"
    rescue
      ""
    end

    def current_task
      @board.filtered_tasks[@board.current_row]
    end

    def enter_detail_mode
      task = current_task
      return unless task

      @content_lines = []
      @detail_scroll = 0
      loading("Loading #{task.title.slice(0, 35)}...") do
        @content_lines = @client.fetch_page_content(task.id).split("\n")
      end
      @mode = :detail
    end

    def refresh
      loading("Refreshing tasks...") do
        tasks = @client.fetch_tasks_by_sprint(@current_sprint[:id])
        @board.refresh(tasks)
        @list_state.select(0)
        @owner_list_state.select(0)
      end
      @status_message = "Refreshed! #{@board.all_tasks.length} tasks"
      @mode = :board
    end

    def open_in_browser
      task = current_task
      return unless task
      system("open", task.url)
      @status_message = "Opened in browser"
    end

    def filter_sprints(sprints, query)
      return sprints if query.nil? || query.empty?
      sprints.select { |s| s[:name].downcase.include?(query.downcase) }
    end

    def loading(message, &block)
      @loading_message = message
      @loading_error   = nil
      @mode            = :loading

      done   = false
      error  = nil
      thread = Thread.new do
        block.call
      rescue => e
        error = e
      ensure
        done = true
      end

      until done
        @loading_tick += 1
        @tui.draw { |frame| render(frame) }
        @tui.poll_event(timeout: 0.08)  # ~12fps, non-blocking
      end

      thread.join
      raise error if error
    end

    def loading_error(message)
      @loading_error = message
      @mode          = :loading
      @tui.draw { |frame| render(frame) }
    end

    def vsplit(area, *constraints)
      @tui.layout_split(area, direction: :vertical, constraints:)
    end

    def popup_area(area, width:, height:)
      v = @tui.layout_split(area, direction: :vertical, constraints: [
        @tui.constraint_fill(1),
        @tui.constraint_length(height),
        @tui.constraint_fill(1),
      ])
      @tui.layout_split(v[1], direction: :horizontal, constraints: [
        @tui.constraint_fill(1),
        @tui.constraint_length(width),
        @tui.constraint_fill(1),
      ])[1]
    end

    def format_time(time_str)
      return "" unless time_str
      time = Time.parse(time_str).localtime
      diff = Time.now - time
      if    diff < 60      then "just now"
      elsif diff < 3600    then "#{(diff / 60).to_i}m ago"
      elsif diff < 86400   then "#{(diff / 3600).to_i}h ago"
      elsif diff < 604_800 then "#{(diff / 86400).to_i}d ago"
      else  time.strftime("%m/%d")
      end
    rescue
      ""
    end

    def status_style(status)
      case status
      when "Done"                          then @s_green
      when "In Progress", "PR Reviewing"  then @s_yellow
      when "In Development"               then @tui.style(fg: :blue)
      when "PM Retest"                    then @tui.style(fg: :magenta)
      else @s_dim
      end
    end

    def priority_style(priority)
      case priority
      when "Urgent", "High", "P1" then @s_red
      when "Medium", "P2"         then @s_yellow
      when "Low", "P3"            then @s_green
      else @tui.style
      end
    end
  end
end
