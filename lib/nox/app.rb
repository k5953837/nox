# frozen_string_literal: true

module Nox
  SPINNER = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

  MOON_PHASES = %w[🌑 🌒 🌓 🌔 🌕 🌖 🌗 🌘].freeze

  NOX_ART = [
    "███╗   ██╗  ██████╗  ██╗  ██╗",
    "████╗  ██║ ██╔═══██╗ ╚██╗██╔╝",
    "██╔██╗ ██║ ██║   ██║  ╚███╔╝ ",
    "██║╚██╗██║ ██║   ██║  ██╔██╗ ",
    "██║ ╚████║ ╚██████╔╝ ██╔╝ ██╗",
    "╚═╝  ╚═══╝  ╚═════╝  ╚═╝  ╚═╝",
  ].freeze

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
      @detail_sub_tasks    = []
      @owner_area          = nil
      @task_area           = nil
      @sprint_menu_area    = nil
      @assign_menu_idx     = 0
      @assign_menu_area    = nil
      @assign_selected_ids = []
      @pre_assign_mode     = :board
      @workspace_users     = []
      @last_click_time     = 0.0
      @last_click_x        = -1
      @last_click_y        = -1
    end

    def run
      RatatuiRuby.run do |tui|
        @tui = tui
        init_styles

        # ── Loading phase ──────────────────────────────────────────────────────
        err = loading("Connecting to Notion...") do
          @loading_message = "Checking current sprint..."
          @current_sprint  = @client.fetch_current_sprint
          if @current_sprint
            @loading_message = "✓ Current sprint detected"
            sleep 0.3
          end
        end
        if err
          loading_error("Notion API error: #{err.message.slice(0, 44)}  Press any key to exit.")
          @tui.poll_event
          next
        end

        unless @current_sprint
          loading_error("No current sprint found. Press any key to exit.")
          @tui.poll_event
          next
        end

        err = loading("Fetching tasks...") do
          tasks = @client.fetch_tasks_by_sprint(@current_sprint[:id])
          @loading_message = "Building board..."
          @board = Board.new(tasks)
          @list_state = RatatuiRuby::ListState.new(nil)
          @list_state.select(0) unless tasks.empty?
          @owner_list_state = RatatuiRuby::ListState.new(nil)
          @owner_list_state.select(0)
          @loading_message = "✓ #{tasks.length} tasks ready"
          sleep 0.3
        end
        if err
          loading_error("Failed to load tasks: #{err.message.slice(0, 40)}  Press any key to exit.")
          @tui.poll_event
          next
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
      when :assign_menu then render_assign_menu(frame)
      end
    end

    def render_loading(frame)
      return render_loading_error(frame) if @loading_error

      area = frame.area
      box_h = [14, area.height].min
      box_w = [66, area.width].min

      _, mid, _ = vsplit(area,
        @tui.constraint_fill(1),
        @tui.constraint_length(box_h),
        @tui.constraint_fill(1)
      )
      _, box_area, _ = @tui.layout_split(mid, direction: :horizontal, constraints: [
        @tui.constraint_fill(1),
        @tui.constraint_length(box_w),
        @tui.constraint_fill(1),
      ])

      # Art pulses between cyan and blue
      art_style  = (@loading_tick / 4).even? ? @s_bold_cyan : @tui.style(fg: :blue, modifiers: [:bold])
      spin_style = @s_bold_cyan

      moon   = MOON_PHASES[@loading_tick / 3 % MOON_PHASES.length]
      spin   = SPINNER[@loading_tick % SPINNER.length]
      bounce = loading_bounce_bar(@loading_tick)

      lines = [
        @tui.text_line(spans: []),
        *NOX_ART.map { |row| @tui.text_line(spans: [@tui.text_span(content: row, style: art_style)]) },
        @tui.text_line(spans: [@tui.text_span(content: "Notion TUI", style: @s_dim)]),
        @tui.text_line(spans: []),
        @tui.text_line(spans: [
          @tui.text_span(content: "#{moon}  "),
          @tui.text_span(content: spin, style: spin_style),
          @tui.text_span(content: "  #{@loading_message}", style: @s_dim),
        ]),
        @tui.text_line(spans: [@tui.text_span(content: bounce, style: @s_dim)]),
        @tui.text_line(spans: []),
      ]

      frame.render_widget(
        @tui.paragraph(text: lines, alignment: :center),
        box_area
      )
    end

    def render_loading_error(frame)
      area = frame.area
      _, mid, _ = vsplit(area,
        @tui.constraint_fill(1),
        @tui.constraint_length(7),
        @tui.constraint_fill(1)
      )
      _, box_area, _ = @tui.layout_split(mid, direction: :horizontal, constraints: [
        @tui.constraint_fill(1),
        @tui.constraint_length(60),
        @tui.constraint_fill(1),
      ])

      err_style = @tui.style(fg: :red)
      lines = [
        @tui.text_line(spans: [
          @tui.text_span(content: "🌙 "),
          @tui.text_span(content: "nox", style: @s_bold_cyan),
        ]),
        @tui.text_line(spans: []),
        @tui.text_line(spans: [
          @tui.text_span(content: "✗  ", style: err_style),
          @tui.text_span(content: @loading_error, style: err_style),
        ]),
      ]
      frame.render_widget(
        @tui.paragraph(text: lines, alignment: :center),
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
      # Status distribution mini-bar
      by_status = @board.filtered_tasks.group_by(&:status).transform_values(&:length)
      header_spans << @tui.text_span(content: "  ")
      STATUS_SYMBOLS.each do |status, (sym, color)|
        count = by_status[status] || 0
        next if count.zero?
        header_spans << @tui.text_span(content: "#{sym}#{count} ", style: @tui.style(fg: color))
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
      @owner_area, @task_area = @tui.layout_split(main_area,
        direction: :horizontal,
        constraints: [
          @tui.constraint_length(owner_width),
          @tui.constraint_fill(1),
        ]
      )

      render_owner_pane(frame, @owner_area)
      render_task_pane(frame, @task_area)

      # Footer — context-sensitive hints
      footer_text = if @search_mode
        "/#{@board.search_query}█  Esc: cancel  Backspace: delete"
      elsif @status_message
        @status_message
      elsif @active_pane == :owners
        "j/k: move  g/G: first/last  Tab/Enter: → tasks  s: sprint  r: refresh  q: quit"
      else
        "j/k: move  g/G: first/last  Enter: open  /: search  a: assign  o: browser  Tab: → owners  s: sprint  r: refresh  q: quit"
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
        sub_indicator  = task.has_sub_tasks? ? "▾#{task.sub_item_ids.length} " : ""
        @tui.text_line(spans: [
          @tui.text_span(content: "#{dot} #{task.title}  "),
          @tui.text_span(content: sub_indicator, style: @tui.style(fg: :cyan)),
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

      has_subs = !@detail_sub_tasks.empty?
      sub_area_h = has_subs ? [@detail_sub_tasks.length + 2, 10].min : 0
      meta_height = task.done? ? 9 : 8
      constraints = [
        @tui.constraint_length(meta_height),
        @tui.constraint_fill(1),
      ]
      constraints << @tui.constraint_length(sub_area_h) if has_subs
      constraints << @tui.constraint_length(1)

      areas = vsplit(frame.area, *constraints)
      meta_area    = areas[0]
      content_area = areas[1]
      sub_area     = has_subs ? areas[2] : nil
      footer_area  = areas.last
      @detail_height = content_area.height

      idx   = @board.current_row
      total = @board.filtered_tasks.length
      nav   = total > 1 ? " #{idx + 1}/#{total}" : ""

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
        @tui.text_line(spans: [
          @tui.text_span(content: " Updated:   "),
          @tui.text_span(content: format_time(task.updated_at), style: @s_dim)
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
            title: " #{task.title}#{nav} ",
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

      # Sub-tasks section
      if has_subs && sub_area
        sub_lines = @detail_sub_tasks.map do |st|
          sym, sym_color = STATUS_SYMBOLS[st.status] || ["·", :dark_gray]
          assignee = st.assignee ? "  #{st.assignee}" : ""
          @tui.text_line(spans: [
            @tui.text_span(content: "  #{sym} ", style: @tui.style(fg: sym_color)),
            @tui.text_span(content: st.title),
            @tui.text_span(content: assignee, style: @s_dim),
          ])
        end
        frame.render_widget(
          @tui.paragraph(
            text: sub_lines,
            block: @tui.block(
              title: " Sub-tasks (#{@detail_sub_tasks.length}) ",
              borders: [:top],
              border_style: @s_dim
            )
          ),
          sub_area
        )
      end

      total    = @content_lines.length
      position = total.zero? ? "" : " #{@detail_scroll + 1}-#{[@detail_scroll + @detail_height, total].min}/#{total}  "
      frame.render_widget(
        @tui.paragraph(
          text: @tui.text_line(spans: [
            @tui.text_span(content: " j/k: scroll  Space/b: page  g/G: top/bottom  n/p: next/prev  a: assign  o: open  Esc/q: back", style: @s_dim),
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

      @sprint_menu_area = popup_area(frame.area, width: 64, height: [filtered.length + 4, 22].min)
      frame.render_widget(@tui.clear, @sprint_menu_area)
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
        @sprint_menu_area
      )
    end

    def render_assign_menu(frame)
      task  = current_task
      users = @workspace_users
      items = users.map { |u|
        check = @assign_selected_ids.include?(u[:id]) ? "☑ " : "☐ "
        "#{check}#{u[:name]}"
      }

      menu_h = [users.length + 4, 18].min
      @assign_menu_area = popup_area(frame.area, width: 44, height: menu_h)
      frame.render_widget(@tui.clear, @assign_menu_area)
      frame.render_widget(
        @tui.list(
          items: items.empty? ? ["(no users found)"] : items,
          selected_index: @assign_menu_idx,
          highlight_style: @s_selected,
          highlight_symbol: "▸ ",
          highlight_spacing: :always,
          block: @tui.block(
            title: " Assign: #{task&.title&.slice(0, 20)}  Space: toggle  Enter: save ",
            borders: [:all],
            border_style: @s_bold_cyan
          )
        ),
        @assign_menu_area
      )
    end

    # ── Event Handling ──────────────────────────────────────────────────────────

    def handle_event(event)
      case @mode
      when :board       then handle_board_event(event)
      when :detail      then handle_detail_event(event)
      when :sprint_menu then handle_sprint_menu_event(event)
      when :assign_menu then handle_assign_menu_event(event)
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
        if @search_mode || !@board.search_query.empty?
          @search_mode = false
          @board.search("")
          @list_state.select(0)
        else
          # Reset owner filter back to "(all)"
          owner_jump(:first)
        end
      in { type: :key, code: "backspace" }
        if @search_mode
          @board.search(@board.search_query[0..-2])
          @list_state.select(0)
        end
      in { type: :key, code: String => char } if @search_mode && char.length == 1 && char.match?(/[[:print:]]/)
        @board.search(@board.search_query + char)
        @list_state.select(0)

      # ── Mouse ────────────────────────────────────────────────────────────────
      in { type: :mouse, kind: "down", button: "left", x:, y: } if !@search_mode
        handle_mouse_click(x, y)
      in { type: :mouse, kind: "scroll_up", x:, y: } if !@search_mode
        handle_mouse_scroll(:up, x, y)
      in { type: :mouse, kind: "scroll_down", x:, y: } if !@search_mode
        handle_mouse_scroll(:down, x, y)

      # ── Global ────────────────────────────────────────────────────────────────
      in { type: :key, code: "a" }
        if @active_pane == :tasks && current_task
          @workspace_users = @client.fetch_users if @workspace_users.empty?
          @assign_menu_idx     = 0
          @assign_selected_ids = current_task.owner_ids.dup
          @pre_assign_mode     = :board
          @mode = :assign_menu
        end
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
      in { type: :key, code: "n" }
        @board.move_down
        @list_state.select(@board.current_row)
        enter_detail_mode
      in { type: :key, code: "p" }
        @board.move_up
        @list_state.select(@board.current_row)
        enter_detail_mode
      in { type: :key, code: "a" }
        if current_task
          @workspace_users = @client.fetch_users if @workspace_users.empty?
          @assign_menu_idx     = 0
          @assign_selected_ids = current_task.owner_ids.dup
          @pre_assign_mode     = :detail
          @mode = :assign_menu
        end
      in { type: :key, code: "o" }
        open_in_browser
      in { type: :mouse, kind: "scroll_up" }
        @detail_scroll = [@detail_scroll - 1, 0].max
      in { type: :mouse, kind: "scroll_down" }
        @detail_scroll = [@detail_scroll + 1, max_scroll].min
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
        confirm_sprint_selection(filtered)
      in { type: :key, code: "esc" }
        @mode = :board
      in { type: :key, code: "backspace" }
        @sprint_search_query = @sprint_search_query[0..-2]
        @sprint_menu_idx     = 0
      in { type: :key, code: String => char } if char.length == 1 && char.match?(/[[:print:]]/)
        @sprint_search_query += char
        @sprint_menu_idx     = 0
      in { type: :mouse, kind: "down", button: "left", x:, y: }
        if @sprint_menu_area&.contains?(x, y)
          item_y = y - @sprint_menu_area.y - 1
          if item_y >= 0
            now          = Time.now.to_f
            double_click = (now - @last_click_time < 0.4) && @last_click_x == x && @last_click_y == y
            @last_click_time = now
            @last_click_x    = x
            @last_click_y    = y

            @sprint_menu_idx = [item_y, max_idx].min
            confirm_sprint_selection(filtered) if double_click
          end
        else
          @mode = :board  # click outside dismisses
        end
      else
        nil
      end
    end

    def handle_assign_menu_event(event)
      max_idx = [@workspace_users.length - 1, 0].max

      case event
      in { type: :key, code: "j" | "down" }
        @assign_menu_idx = [@assign_menu_idx + 1, max_idx].min
      in { type: :key, code: "k" | "up" }
        @assign_menu_idx = [@assign_menu_idx - 1, 0].max
      in { type: :key, code: " " }
        toggle_assign_user(@assign_menu_idx)
      in { type: :key, code: "enter" }
        confirm_assign_selection
      in { type: :key, code: "esc" }
        @mode = @pre_assign_mode || :board
      in { type: :mouse, kind: "down", button: "left", x:, y: }
        if @assign_menu_area&.contains?(x, y)
          item_y = y - @assign_menu_area.y - 1
          if item_y >= 0
            clicked_idx = [item_y, max_idx].min
            @assign_menu_idx = clicked_idx
            toggle_assign_user(clicked_idx)
          end
        else
          @mode = @pre_assign_mode || :board
        end
      else
        nil
      end
    end

    # ── Helpers ─────────────────────────────────────────────────────────────────

    def toggle_assign_user(idx)
      user = @workspace_users[idx]
      return unless user
      if @assign_selected_ids.include?(user[:id])
        @assign_selected_ids.delete(user[:id])
      else
        @assign_selected_ids << user[:id]
      end
    end

    def confirm_assign_selection
      task = current_task
      return unless task

      err = loading("Updating owners...") do
        @client.update_task_owner(task.id, @assign_selected_ids)
        task.owners = @assign_selected_ids.map { |uid|
          u = @workspace_users.find { |w| w[:id] == uid }
          { id: uid, name: u&.dig(:name) || "Unknown" }
        }
      end

      names = task.assignee
      @status_message = if err
        "Failed to update: #{err.message.slice(0, 40)}"
      elsif names
        "Assigned to #{names}"
      else
        "Unassigned"
      end
      @mode = @pre_assign_mode || :board
    end

    def confirm_sprint_selection(filtered)
      return if filtered.empty?
      selected = filtered[@sprint_menu_idx]
      if selected && selected[:id] != @current_sprint[:id]
        @current_sprint = selected
        err = loading("Loading #{selected[:name]}...") do
          tasks = @client.fetch_tasks_by_sprint(selected[:id])
          @board = Board.new(tasks)
          @list_state.select(0)
          @owner_list_state.select(0)
        end
        @status_message = err ? "Failed to load sprint: #{err.message.slice(0, 35)}" : "Switched to: #{selected[:name]}"
      end
      @mode = :board
    end

    def handle_mouse_click(x, y)
      now          = Time.now.to_f
      double_click = (now - @last_click_time < 0.4) && @last_click_x == x && @last_click_y == y
      @last_click_time = now
      @last_click_x    = x
      @last_click_y    = y

      if @owner_area&.contains?(x, y)
        @active_pane = :owners
        item_y = y - @owner_area.y - 1   # subtract top border
        return if item_y < 0
        owners  = @board.all_owners
        new_idx = [(@owner_list_state.offset || 0) + item_y, owners.length].min
        if new_idx != (@owner_list_state.selected || 0)
          @owner_list_state.select(new_idx)
          owner = new_idx == 0 ? nil : owners[new_idx - 1]
          @board.filter_by_owner(owner)
          @list_state.select(0)
        end
        @active_pane = :tasks if double_click

      elsif @task_area&.contains?(x, y)
        @active_pane = :tasks
        item_y  = y - @task_area.y - 1   # subtract top border
        return if item_y < 0
        tasks   = @board.filtered_tasks
        new_idx = [(@list_state.offset || 0) + item_y, tasks.length - 1].min
        new_idx = [new_idx, 0].max
        @board.move_to(new_idx)
        @list_state.select(new_idx)
        enter_detail_mode if double_click
      end
    end

    def handle_mouse_scroll(direction, x, y)
      if @owner_area&.contains?(x, y)
        direction == :up ? owner_move(:up) : owner_move(:down)
      elsif @task_area&.contains?(x, y)
        if direction == :up
          @board.move_up
          @list_state.select(@board.current_row)
        else
          @board.move_down
          @list_state.select(@board.current_row)
        end
      end
    end

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

    def loading_bounce_bar(tick, width: 32)
      period = (width - 1) * 2
      pos    = tick % period
      pos    = period - pos if pos >= width
      chars  = ["░"] * width
      chars[pos] = "█"
      chars[[pos - 1, 0].max] = "▓" if pos >= 1
      chars[[pos - 2, 0].max] = "▒" if pos >= 2
      chars.join
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

      @content_lines    = []
      @detail_sub_tasks = []
      @detail_scroll    = 0
      err = loading("Loading #{task.title.slice(0, 35)}...") do
        content_thread = Thread.new { @client.fetch_page_content(task.id).split("\n") }
        sub_thread     = task.has_sub_tasks? ? Thread.new { @client.fetch_sub_tasks(task.id) } : nil
        @content_lines    = content_thread.value
        @detail_sub_tasks = sub_thread&.value || []
      end
      if err
        @status_message = "Error: #{err.message.slice(0, 50)}"
        @mode = :board
      else
        @mode = :detail
      end
    end

    def refresh
      # Remember current owner by name so we can restore after refresh
      saved_owner_idx  = @owner_list_state&.selected || 0
      saved_owner_name = saved_owner_idx == 0 ? nil : @board.all_owners[saved_owner_idx - 1]

      err = loading("Refreshing tasks...") do
        tasks = @client.fetch_tasks_by_sprint(@current_sprint[:id])
        @board.refresh(tasks)
      end

      # Restore owner filter — fall back to "(all)" if owner no longer exists
      if saved_owner_name && (new_idx = @board.all_owners.index(saved_owner_name))
        @owner_list_state.select(new_idx + 1)
        @board.filter_by_owner(saved_owner_name)
      else
        @owner_list_state.select(0)
        @board.filter_by_owner(nil)
      end
      @list_state.select(0)

      @status_message = err ? "Refresh failed: #{err.message.slice(0, 45)}" : "Refreshed! #{@board.all_tasks.length} tasks"
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
      error  # return error instead of raising; callers decide how to handle
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
