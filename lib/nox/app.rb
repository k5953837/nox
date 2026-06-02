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

  PRIORITY_LEVELS = {
    "P1" => ["P1", :red],
    "P2" => ["P2", :yellow],
    "P3" => ["P3", :cyan],
  }.freeze

  STATUS_SYMBOLS = {
    "Done"           => ["DON", :green],
    "In Progress"    => ["WIP", :yellow],
    "In Development" => ["DEV", :blue],
    "PR Reviewing"   => ["RVW", :cyan],
    "PM Retest"      => ["PMR", :magenta],
    "Pending"        => ["HLD", :dark_gray],
    "Not started"    => ["NEW", :dark_gray],
  }.freeze

  STATUS_OPTIONS = STATUS_SYMBOLS.keys.freeze

  KEYMAP = [
    ["NAVIGATION", [
      ["j / k       ", "move down / up"],
      ["g / G       ", "first / last"],
      ["Tab         ", "switch pane"],
      ["Enter / →   ", "open detail"],
      ["Esc / ←     ", "back / dismiss"],
      ["n / p       ", "next / prev task (in detail)"],
      ["Space / b   ", "page down / up (in detail)"],
    ]],
    ["ACTIONS", [
      ["S           ", "change status"],
      ["a           ", "assign owners"],
      ["o           ", "open in browser"],
      ["r           ", "refresh from Notion"],
    ]],
    ["FILTERS", [
      ["/           ", "search"],
      ["f           ", "filter by status"],
      ["s           ", "switch sprint"],
    ]],
    ["APP", [
      ["?           ", "this help"],
      ["q / Ctrl-C  ", "quit"],
    ]],
  ].freeze

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
      @status_menu_idx     = 0
      @status_menu_area    = nil
      @status_filter_idx      = 0
      @status_filter_area     = nil
      @status_filter_selected = []
      @help_area           = nil
      @previous_mode       = :board
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
      @s_cyan      = @tui.style(fg: :cyan)
      @s_bold_cyan = @tui.style(fg: :cyan, modifiers: [:bold])
      @s_h1        = @tui.style(fg: :cyan, modifiers: [:bold, :underlined])
      @s_yellow    = @tui.style(fg: :yellow)
      @s_red       = @tui.style(fg: :red)
      @s_green     = @tui.style(fg: :green)
      @style_cache = {}
    end

    # ── Rendering ───────────────────────────────────────────────────────────────

    def render(frame)
      @terminal_width = frame.area.width
      case @mode
      when :loading     then render_loading(frame)
      when :board       then render_board(frame)
      when :detail      then render_detail(frame)
      when :sprint_menu then render_sprint_menu(frame)
      when :assign_menu then render_assign_menu(frame)
      when :status_menu then render_status_menu(frame)
      when :status_filter then render_status_filter(frame)
      when :help        then render_help(frame)
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
      show_search = @search_mode || !@board.search_query.empty?
      constraints = [@tui.constraint_length(2)]
      constraints << @tui.constraint_length(3) if show_search
      constraints << @tui.constraint_fill(1)
      constraints << @tui.constraint_length(1)

      areas       = vsplit(frame.area, *constraints)
      header_area = areas[0]
      search_area = show_search ? areas[1] : nil
      main_area   = show_search ? areas[2] : areas[1]
      footer_area = areas.last

      # Header — Lunar Codex: moon phase and bar share one ratio computation
      sprint_name  = @current_sprint[:name]
      ratio        = sprint_progress_ratio(@current_sprint)
      moon         = MOON_PHASES[(ratio * (MOON_PHASES.length - 1)).round]
      progress_bar = ratio_bar(ratio, width: 8)
      header_spans = [
        @tui.text_span(content: " #{moon}  "),
        @tui.text_span(content: "nox", style: @s_bold_cyan),
        @tui.text_span(content: " · ", style: @s_dim),
        @tui.text_span(content: sprint_name, style: @s_yellow),
        @tui.text_span(content: "  #{progress_bar}", style: @s_cyan),
      ]

      by_status   = @board.status_counts
      done_count  = by_status["Done"] || 0
      total_count = by_status.values.sum
      header_spans << @tui.text_span(content: "  ·  ", style: @s_dim)
      header_spans << @tui.text_span(content: "✓ #{done_count}/#{total_count}", style: @s_green)

      header_spans << @tui.text_span(content: "   │   ", style: @s_dim)
      STATUS_SYMBOLS.each do |status, (sym, color)|
        count = by_status[status] || 0
        next if count.zero?
        header_spans << @tui.text_span(content: "#{sym} #{count}  ", style: @tui.style(fg: color))
      end
      frame.render_widget(
        @tui.paragraph(
          text: @tui.text_line(spans: header_spans),
          block: @tui.block(borders: [:bottom])
        ),
        header_area
      )

      render_search_bar(frame, search_area) if search_area

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
      mode_label, hints = if @search_mode
        ["SEARCH",  "type to filter · Esc cancel · Backspace delete · Enter keep filter"]
      elsif @active_pane == :owners
        ["OWNERS",  "j/k move · Tab/Enter → tasks · f filter · s sprint · r refresh · ? help · q quit"]
      else
        ["BOARD",   "j/k move · Enter open · / search · f filter · S status · a assign · o browser · s sprint · ? help · q quit"]
      end

      footer_spans = if @status_message
        [@tui.text_span(content: @status_message, style: @s_yellow)]
      else
        [
          @tui.text_span(content: " #{mode_label} ", style: @tui.style(fg: :black, bg: :cyan, modifiers: [:bold])),
          @tui.text_span(content: "  #{hints}", style: @s_dim),
        ]
      end
      @status_message = nil
      frame.render_widget(
        @tui.paragraph(text: @tui.text_line(spans: footer_spans)),
        footer_area
      )
    end

    def render_search_bar(frame, area)
      cursor       = @search_mode ? "█" : ""
      border_style = @search_mode ? @s_bold_cyan : @s_dim
      hit_count    = @board.filtered_tasks.length
      title        = @board.search_query.empty? ? " Search " : " Search  ·  #{hit_count} match#{'es' unless hit_count == 1} "

      frame.render_widget(
        @tui.paragraph(
          text: @tui.text_line(spans: [
            @tui.text_span(content: " / ", style: @s_bold_cyan),
            @tui.text_span(content: @board.search_query, style: @s_yellow),
            @tui.text_span(content: cursor, style: @s_bold_cyan),
          ]),
          block: @tui.block(title:, borders: [:all], border_style:)
        ),
        area
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
          @tui.text_span(content: "  #{total}", style: @s_dim),
        ]),
        *owners.map { |o|
          c = counts[o] || 0
          @tui.text_line(spans: [
            @tui.text_span(content: o),
            @tui.text_span(content: "  #{density_bar(c, total)} #{c}", style: @s_dim),
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
      base = active_owner ? "#{active_owner} (#{tasks.length})" : "Tasks (#{tasks.length}/#{@board.all_tasks.length})"
      base += " · #{@board.status_filter.size} status" if @board.status_filter.size.positive?
      title = " #{base} "

      if tasks.empty?
        frame.render_widget(
          @tui.paragraph(
            text: empty_task_lines(active_owner),
            block: @tui.block(title:, borders: [:all], border_style:)
          ),
          area
        )
        return
      end

      items = tasks.map do |task|
        sym, sym_color = status_glyph(task.status)
        pcode, pcolor  = priority_badge(task.priority) || ["-", :dark_gray]
        parent_badge   = task.has_sub_tasks? ? "▾#{task.sub_item_ids.length}" : ""
        updated        = format_time(task.updated_at)
        assignee       = task.assignee || ""

        spans = [
          @tui.text_span(content: "#{sym.ljust(3)} ",          style: @tui.style(fg: sym_color)),
          @tui.text_span(content: "#{pcode.ljust(2)} ",        style: @tui.style(fg: pcolor)),
          @tui.text_span(content: "#{parent_badge.ljust(3)} ", style: @s_cyan),
        ]
        spans << @tui.text_span(content: "  ↳  ", style: @s_cyan) if task.sub_task?
        spans << @tui.text_span(content: "#{task.title}  ")
        spans << @tui.text_span(content: "#{updated}  #{assignee}", style: @s_dim)
        @tui.text_line(spans: spans)
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
      meta_height = task.done? ? 10 : 9
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

      status_code, status_color = status_glyph(task.status)
      prio_code, prio_color     = priority_badge(task.priority) || ["", nil]
      sprint_str                = @current_sprint ? "#{@current_sprint[:name]}#{sprint_date_str(@current_sprint)}" : "—"

      meta_lines = [
        meta_row(label: "STATUS",   code: status_code, code_color: status_color, value: task.status || "—"),
        meta_row(label: "PRIO",     code: prio_code,   code_color: prio_color,   value: task.priority || "—"),
        meta_row(label: "OWNER",    value: task.assignee || "—"),
        meta_row(label: "UPDATED",  value: format_time(task.updated_at), value_style: @s_dim),
        meta_row(label: "SPRINT",   value: sprint_str, value_style: @s_yellow),
      ]
      if task.done?
        meta_lines << meta_row(label: "COMPLETED", value: task.completion_time || "—")
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
        lines   = visible.map { |s| content_struct_to_line(s) }
        frame.render_widget(
          @tui.paragraph(text: lines, block: @tui.block(borders: [:bottom])),
          content_area
        )
      end

      # Sub-tasks section
      if has_subs && sub_area
        sub_lines = @detail_sub_tasks.map do |st|
          sym, sym_color = status_glyph(st.status)
          assignee = st.assignee ? "  #{st.assignee}" : ""
          @tui.text_line(spans: [
            @tui.text_span(content: "  #{sym.ljust(3)} ", style: @tui.style(fg: sym_color)),
            @tui.text_span(content: st.title),
            @tui.text_span(content: assignee, style: @s_dim),
          ])
        end
        sub_done  = @detail_sub_tasks.count(&:done?)
        sub_total = @detail_sub_tasks.length
        sub_bar   = density_bar(sub_done, sub_total)
        frame.render_widget(
          @tui.paragraph(
            text: sub_lines,
            block: @tui.block(
              title: " Sub-tasks  #{sub_done}/#{sub_total} done  #{sub_bar} ",
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
            @tui.text_span(content: " DETAIL ", style: @tui.style(fg: :black, bg: :cyan, modifiers: [:bold])),
            @tui.text_span(content: "  j/k scroll · n/p next/prev · S status · a assign · o open · ? help · Esc back", style: @s_dim),
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

    def render_help(frame)
      lines = []
      KEYMAP.each_with_index do |(section, entries), section_idx|
        lines << @tui.text_line(spans: []) unless section_idx == 0
        lines << @tui.text_line(spans: [
          @tui.text_span(content: " #{section}", style: @s_bold_cyan),
        ])
        entries.each do |key, desc|
          lines << @tui.text_line(spans: [
            @tui.text_span(content: "   #{key}", style: @s_yellow),
            @tui.text_span(content: desc, style: @s_dim),
          ])
        end
      end

      total_rows = KEYMAP.sum { |_, entries| entries.length + 1 } + KEYMAP.length - 1 + 2
      @help_area = popup_area(frame.area, width: 52, height: [total_rows + 2, frame.area.height - 4].min)
      frame.render_widget(@tui.clear, @help_area)
      frame.render_widget(
        @tui.paragraph(
          text: lines,
          block: @tui.block(
            title: " Keyboard Shortcuts  ·  ? / Esc to dismiss ",
            borders: [:all],
            border_style: @s_bold_cyan
          )
        ),
        @help_area
      )
    end

    def render_status_menu(frame)
      task  = current_task
      items = STATUS_OPTIONS.map do |name|
        sym, _color = STATUS_SYMBOLS[name]
        marker = (task && task.status == name) ? "→" : " "
        "#{marker} #{sym.ljust(3)}  #{name}"
      end

      menu_h = [STATUS_OPTIONS.length + 4, 14].min
      @status_menu_area = popup_area(frame.area, width: 44, height: menu_h)
      frame.render_widget(@tui.clear, @status_menu_area)
      frame.render_widget(
        @tui.list(
          items: items,
          selected_index: @status_menu_idx,
          highlight_style: @s_selected,
          highlight_symbol: "▸ ",
          highlight_spacing: :always,
          block: @tui.block(
            title: " Status: #{task&.title&.slice(0, 18)}  Enter: save  Esc: cancel ",
            borders: [:all],
            border_style: @s_bold_cyan
          )
        ),
        @status_menu_area
      )
    end

    def render_status_filter(frame)
      options = status_filter_options
      counts  = @board.status_counts
      items = options.map do |name|
        check  = @status_filter_selected.include?(name) ? "☑ " : "☐ "
        sym, _ = status_glyph(name)
        "#{check}#{sym.ljust(3)}  #{name.ljust(14)} #{counts[name] || 0}"
      end

      active = @status_filter_selected.length
      title  = active.zero? ?
        " Filter Status  Space pick · Enter apply " :
        " Filter Status (#{active})  ⌫ clear · Enter apply "

      menu_h = [options.length + 4, 16].min
      @status_filter_area = popup_area(frame.area, width: 44, height: menu_h)
      frame.render_widget(@tui.clear, @status_filter_area)
      frame.render_widget(
        @tui.list(
          items: items.empty? ? ["(no statuses in view)"] : items,
          selected_index: @status_filter_idx,
          highlight_style: @s_selected,
          highlight_symbol: "▸ ",
          highlight_spacing: :always,
          block: @tui.block(
            title:,
            borders: [:all],
            border_style: @s_bold_cyan
          )
        ),
        @status_filter_area
      )
    end

    # ── Event Handling ──────────────────────────────────────────────────────────

    def handle_event(event)
      case @mode
      when :board       then handle_board_event(event)
      when :detail      then handle_detail_event(event)
      when :sprint_menu then handle_sprint_menu_event(event)
      when :assign_menu then handle_assign_menu_event(event)
      when :status_menu then handle_status_menu_event(event)
      when :status_filter then handle_status_filter_event(event)
      when :help        then handle_help_event(event)
      end
    end

    # Dedicated event handler for when @search_mode is true.
    # Short-circuits before board command dispatch so that printable chars
    # like q / a / o / s / S that double as board hotkeys are captured as
    # search input rather than triggering their action.
    def handle_search_input(event)
      case event
      in { type: :key, code: "esc" }
        @search_mode = false
        @board.search("")
        @list_state.select(0)
      in { type: :key, code: "enter" }
        @search_mode = false   # commit filter, exit input mode (query persists)
      in { type: :key, code: "backspace" }
        @board.search(@board.search_query[0..-2])
        @list_state.select(0)
      in { type: :key, code: "down" }
        @board.move_down
        @list_state.select(@board.current_row)
      in { type: :key, code: "up" }
        @board.move_up
        @list_state.select(@board.current_row)
      in { type: :key, code: String => char } if char.length == 1 && char.match?(/[[:print:]]/)
        @board.search(@board.search_query + char)
        @list_state.select(0)
      else
        nil
      end
    end

    def handle_board_event(event)
      return handle_search_input(event) if @search_mode

      case event
      in { type: :key, code: "q" } | { type: :key, code: "c", modifiers: ["ctrl"] }
        :quit

      # ── Pane switching ────────────────────────────────────────────────────────
      in { type: :key, code: "tab" }
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
      in { type: :key, code: "enter" | "right" }
        if @active_pane == :owners
          @active_pane = :tasks  # Enter on owner → focus tasks pane
        else
          enter_detail_mode
        end
      in { type: :key, code: "o" }
        open_in_browser if @active_pane == :tasks

      # ── Filters ───────────────────────────────────────────────────────────────
      in { type: :key, code: "f" }
        open_status_filter
      in { type: :key, code: "/" }
        @search_mode = true
        @active_pane = :tasks
      in { type: :key, code: "esc" }
        if !@board.search_query.empty?
          @board.search("")
          @list_state.select(0)
        else
          owner_jump(:first)
        end

      # ── Mouse ────────────────────────────────────────────────────────────────
      in { type: :mouse, kind: "down", button: "left", x:, y: }
        handle_mouse_click(x, y)
      in { type: :mouse, kind: "scroll_up", x:, y: }
        handle_mouse_scroll(:up, x, y)
      in { type: :mouse, kind: "scroll_down", x:, y: }
        handle_mouse_scroll(:down, x, y)

      # ── Global ────────────────────────────────────────────────────────────────
      in { type: :key, code: "a" }
        open_assign_menu(from: :board) if @active_pane == :tasks
      in { type: :key, code: "S" } | { type: :key, code: "s", modifiers: ["shift"] }
        open_status_menu(from: :board) if @active_pane == :tasks
      in { type: :key, code: "s" }
        @sprints = @client.fetch_sprints if @sprints.empty?
        @sprint_menu_idx     = 0
        @sprint_search_query = ""
        @mode = :sprint_menu
      in { type: :key, code: "r" }
        refresh
      in { type: :key, code: "?" }
        @previous_mode = :board
        @mode          = :help
      else
        nil
      end
    end

    def handle_detail_event(event)
      max_scroll = [@content_lines.length - @detail_height, 0].max
      page       = @detail_height

      case event
      in { type: :key, code: "esc" | "q" | "left" }
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
        open_assign_menu(from: :detail)
      in { type: :key, code: "S" } | { type: :key, code: "s", modifiers: ["shift"] }
        open_status_menu(from: :detail)
      in { type: :key, code: "o" }
        open_in_browser
      in { type: :key, code: "?" }
        @previous_mode = :detail
        @mode          = :help
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
        @mode = @previous_mode
      in { type: :mouse, kind: "down", button: "left", x:, y: }
        if @assign_menu_area&.contains?(x, y)
          item_y = y - @assign_menu_area.y - 1
          if item_y >= 0
            clicked_idx = [item_y, max_idx].min
            @assign_menu_idx = clicked_idx
            toggle_assign_user(clicked_idx)
          end
        else
          @mode = @previous_mode
        end
      else
        nil
      end
    end

    def handle_status_menu_event(event)
      max_idx = [STATUS_OPTIONS.length - 1, 0].max

      case event
      in { type: :key, code: "j" | "down" }
        @status_menu_idx = [@status_menu_idx + 1, max_idx].min
      in { type: :key, code: "k" | "up" }
        @status_menu_idx = [@status_menu_idx - 1, 0].max
      in { type: :key, code: "enter" }
        confirm_status_selection
      in { type: :key, code: "esc" }
        @mode = @previous_mode
      in { type: :mouse, kind: "down", button: "left", x:, y: }
        if @status_menu_area&.contains?(x, y)
          item_y = y - @status_menu_area.y - 1
          if item_y >= 0
            @status_menu_idx = [item_y, max_idx].min
            confirm_status_selection
          end
        else
          @mode = @previous_mode
        end
      else
        nil
      end
    end

    def handle_status_filter_event(event)
      options = status_filter_options
      max_idx = [options.length - 1, 0].max

      case event
      in { type: :key, code: "j" | "down" }
        @status_filter_idx = [@status_filter_idx + 1, max_idx].min
      in { type: :key, code: "k" | "up" }
        @status_filter_idx = [@status_filter_idx - 1, 0].max
      in { type: :key, code: " " }
        toggle_status_filter(options[@status_filter_idx])
      in { type: :key, code: "backspace" }
        @status_filter_selected = []
      in { type: :key, code: "enter" }
        confirm_status_filter
      in { type: :key, code: "esc" }
        @mode = :board
      in { type: :mouse, kind: "down", button: "left", x:, y: }
        if @status_filter_area&.contains?(x, y)
          item_y = y - @status_filter_area.y - 1
          if item_y >= 0
            @status_filter_idx = [item_y, max_idx].min
            toggle_status_filter(options[@status_filter_idx])
          end
        else
          @mode = :board
        end
      else
        nil
      end
    end

    def handle_help_event(event)
      case event
      in { type: :key, code: "?" } | { type: :key, code: "esc" } | { type: :key, code: "q" }
        @mode = @previous_mode
      in { type: :mouse, kind: "down", button: "left", x:, y: }
        @mode = @previous_mode unless @help_area&.contains?(x, y)
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
      @mode = @previous_mode
    end

    def confirm_status_selection
      task = current_task
      new_status = STATUS_OPTIONS[@status_menu_idx]
      if task && new_status && task.status != new_status
        err = loading("Updating status...") do
          @client.update_task_status(task.id, new_status)
          task.status = new_status
        end
        @status_message = err ? "Failed to update: #{err.message.slice(0, 40)}" : "Status set to #{new_status}"
      end
      @mode = @previous_mode
    end

    def open_status_menu(from:)
      return unless current_task
      @status_menu_idx = STATUS_OPTIONS.index(current_task.status) || 0
      @previous_mode   = from
      @mode            = :status_menu
    end

    def open_assign_menu(from:)
      return unless current_task
      @workspace_users     = @client.fetch_users if @workspace_users.empty?
      @assign_menu_idx     = 0
      @assign_selected_ids = current_task.owner_ids.dup
      @previous_mode       = from
      @mode                = :assign_menu
    end

    def open_status_filter
      @status_filter_selected = @board.status_filter.to_a
      @status_filter_idx      = 0
      @mode                   = :status_filter
    end

    # Statuses present in the owner-scoped view, ordered by STATUS_OPTIONS then
    # unknowns. Currently-selected statuses are always included so they stay
    # uncheckable even if they have no tasks in the current scope.
    def status_filter_options
      present = (@board.status_counts.keys + @status_filter_selected).uniq
      STATUS_OPTIONS.select { |s| present.include?(s) } + (present - STATUS_OPTIONS).sort
    end

    def toggle_status_filter(name)
      return unless name
      if @status_filter_selected.include?(name)
        @status_filter_selected.delete(name)
      else
        @status_filter_selected << name
      end
    end

    def confirm_status_filter
      @board.filter_by_statuses(@status_filter_selected)
      @list_state.select(0)
      n = @status_filter_selected.length
      @status_message = n.zero? ? "Status filter cleared" : "Filtering #{n} status#{'es' unless n == 1}"
      @mode = :board
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
      # name + "  " + bar (4) + " " + count
      labels = ["(all)  #{"▰" * 4} #{@board.all_tasks.length}"] +
               owners.map { |o| "#{o}  #{"▰" * 4} #{counts[o] || 0}" }
      max_label = labels.map(&:length).max || 8
      # +5 for borders (2) + highlight symbol "▸ " (2) + padding (1)
      [[max_label + 5, 22].max, 36].min
    end

    # Renders a width-cell ▰/▱ bar from a ratio in [0.0..1.0].
    def ratio_bar(ratio, width:)
      filled = (ratio.clamp(0.0, 1.0) * width).round
      ("▰" * filled) + ("▱" * (width - filled))
    end

    def density_bar(count, max, width: 4)
      return "▱" * width if max <= 0
      ratio_bar(count.to_f / max, width: width)
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
        content_thread = Thread.new { @client.fetch_page_content(task.id) }
        sub_thread     = task.has_sub_tasks? ? Thread.new { @client.fetch_sub_tasks(task.id) } : nil
        @content_lines    = prepare_content(content_thread.value, width: @terminal_width || 80)
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

    # Distinguishes "no search match" / "owner has nothing" / "sprint is empty".
    def empty_task_lines(active_owner)
      headline, hint = if !@board.search_query.empty?
        ["No tasks matching “#{@board.search_query}”", "Esc clear search  ·  Backspace edit"]
      elsif @board.status_filter.size.positive?
        ["No tasks match the status filter", "f adjust filter  ·  ⌫ in filter clears"]
      elsif active_owner
        ["#{active_owner} has no tasks in this sprint", "Tab switch pane  ·  s switch sprint"]
      else
        ["This sprint has no tasks yet", "s switch sprint  ·  r refresh"]
      end

      [
        @tui.text_line(spans: []),
        @tui.text_line(spans: [@tui.text_span(content: "  ╶── empty ──╴", style: @s_dim)]),
        @tui.text_line(spans: []),
        @tui.text_line(spans: [@tui.text_span(content: "  #{headline}")]),
        @tui.text_line(spans: []),
        @tui.text_line(spans: [@tui.text_span(content: "  #{hint}", style: @s_yellow)]),
      ]
    end

    def sprint_progress_bar(sprint, width: 8)
      ratio_bar(sprint_progress_ratio(sprint), width: width)
    end

    # Returns [0.0..1.0] for sprint elapsed time. Tolerates missing dates.
    def sprint_progress_ratio(sprint)
      return 0.0 unless sprint && sprint[:dates] && sprint[:dates]["start"]
      start_d = Date.parse(sprint[:dates]["start"])
      end_d   = sprint[:dates]["end"] ? Date.parse(sprint[:dates]["end"]) : start_d
      total   = (end_d - start_d).to_i
      return 0.0 if total <= 0
      elapsed = (Date.today - start_d).to_i
      [[elapsed.to_f / total, 0.0].max, 1.0].min
    rescue ArgumentError
      0.0
    end

    # 0% → 🌑 new, ~50% → 🌕 full, 100% → 🌘 last waning.
    def sprint_progress_moon(sprint)
      MOON_PHASES[(sprint_progress_ratio(sprint) * (MOON_PHASES.length - 1)).round]
    end

    # Format: " LABEL     CODE   VALUE" with fixed-width columns.
    def meta_row(label:, value:, code: nil, code_color: nil, value_style: nil)
      spans = [
        @tui.text_span(content: " #{label.ljust(10)}", style: @s_dim),
      ]
      if code && !code.empty?
        spans << @tui.text_span(content: code.ljust(5), style: @tui.style(fg: code_color || :white))
      else
        spans << @tui.text_span(content: " " * 5)
      end
      spans << if value_style
        @tui.text_span(content: value.to_s, style: value_style)
      else
        @tui.text_span(content: value.to_s)
      end
      @tui.text_line(spans: spans)
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

    def status_glyph(status)
      return STATUS_SYMBOLS[status] if STATUS_SYMBOLS.key?(status)
      code = status.to_s.gsub(/[^A-Za-z0-9]/, "")[0, 3]
      [code.empty? ? "?" : code.upcase, :dark_gray]
    end

    # Resolves a raw Notion priority to [code, color] by matching the P1-P3
    # prefix — real values look like "P2🟡 - 5wd". Returns nil for High/Medium/
    # Low and unset, which callers render as a dim "-".
    def priority_badge(priority)
      code = priority&.[](/\AP[123]\b/)
      code && PRIORITY_LEVELS[code]
    end

    # ── Content rendering ────────────────────────────────────────────────────────

    def content_struct_to_line(s)
      case s[:type]
      when :heading_1
        @tui.text_line(spans: [@tui.text_span(content: "  #{s[:cached_text]}", style: @s_h1)])
      when :heading_2    then prefix_line("  ● ", @s_cyan, s[:runs], base_mods: [:bold])
      when :heading_3    then prefix_line("  ○ ", @s_dim,  s[:runs], base_mods: [:bold])
      when :empty        then empty_line
      when :bulleted_list  then prefix_line("  • ", @s_dim, s[:runs])
      when :numbered_list  then prefix_line("  #{s[:list_num]}. ", @s_dim, s[:runs])
      when :todo
        sym_style = s[:checked] ? @s_dim : @s_cyan
        prefix_line("  #{s[:checked] ? '☑' : '☐'} ", sym_style, s[:runs])
      when :code_fence
        if s[:opening]
          lang = s[:lang].to_s.empty? ? "" : " #{s[:lang]}"
          @tui.text_line(spans: [@tui.text_span(content: "  ╭─#{lang}", style: @s_dim)])
        else
          @tui.text_line(spans: [@tui.text_span(content: "  ╰─", style: @s_dim)])
        end
      when :code_line    then prefix_line("  │ ", @s_dim,         s[:runs], force_fg: :green)
      when :quote        then prefix_line("  │ ", @s_cyan,        s[:runs], base_mods: [:italic])
      when :callout_open
        @tui.text_line(spans: [@tui.text_span(content: s[:formatted_open], style: s[:bar_style])])
      when :callout_body then prefix_line("  │  ", s[:bar_style], s[:runs])
      when :callout_close
        @tui.text_line(spans: [@tui.text_span(content: s[:formatted_close], style: s[:bar_style])])
      when :toggle       then prefix_line("  ▸ ", @s_dim,         s[:runs])
      when :table_row
        span = s[:header] ? @tui.text_span(content: s[:formatted_content], style: @s_bold_cyan) :
                            @tui.text_span(content: s[:formatted_content])
        @tui.text_line(spans: [span])
      when :table_sep
        @tui.text_line(spans: [@tui.text_span(content: s[:formatted_sep], style: @s_dim)])
      when :divider
        @tui.text_line(spans: [@tui.text_span(content: "  ─────────────────────────────", style: @s_dim)])
      when :media  then single_run_line(s, @s_dim)
      when :error  then single_run_line(s, @s_red)
      else
        s[:runs].empty? ? empty_line : @tui.text_line(spans: [@tui.text_span(content: "  "), *runs_to_spans(s[:runs])])
      end
    end

    def prefix_line(prefix, style, runs, **span_opts)
      @tui.text_line(spans: [
        @tui.text_span(content: prefix, style: style),
        *runs_to_spans(runs, **span_opts),
      ])
    end

    def empty_line
      @tui.text_line(spans: [@tui.text_span(content: "")])
    end

    def single_run_line(s, style)
      @tui.text_line(spans: [@tui.text_span(content: "  #{s[:runs].first&.[](:text)}", style: style)])
    end

    def runs_to_spans(runs, base_mods: [], force_fg: nil)
      runs.map do |run|
        # Build mods in canonical order (bold → italic → crossed_out) so no sort needed
        mods = []
        mods << :bold        if run[:bold]   || base_mods.include?(:bold)
        mods << :italic      if run[:italic] || base_mods.include?(:italic)
        mods << :crossed_out if run[:strikethrough]

        fg = force_fg
        fg ||= :green if run[:code]
        fg ||= notion_color_to_fg(run[:color])

        if mods.any? || fg
          key   = [fg, mods]
          style = @style_cache[key] ||= begin
            args = {}
            args[:fg]        = fg   if fg
            args[:modifiers] = mods if mods.any?
            @tui.style(**args)
          end
          @tui.text_span(content: run[:text], style: style)
        else
          @tui.text_span(content: run[:text])
        end
      end
    end

    def cached_style_for_color(color)
      fg = notion_color_to_fg(color)
      fg ? (@style_cache[[fg, []]] ||= @tui.style(fg: fg)) : @s_dim
    end

    def notion_color_to_fg(color)
      case color
      when "red",    "red_background"    then :red
      when "blue",   "blue_background"   then :blue
      when "green",  "green_background"  then :green
      when "yellow", "yellow_background" then :yellow
      when "orange", "orange_background" then :yellow
      when "pink",   "pink_background"   then :magenta
      when "purple", "purple_background" then :magenta
      when "gray",   "gray_background"   then :dark_gray
      when "brown",  "brown_background"  then :red
      end
    end

    # ── Table column alignment ───────────────────────────────────────────────────

    def prepare_content(structs, width: 80)
      result = []
      i      = 0
      while i < structs.length
        struct = structs[i]

        case struct[:type]
        when :heading_1
          struct[:cached_text] = struct[:runs].map { |r| r[:text] }.join
          result << struct
          i += 1
        when :callout_open
          struct[:bar_style]      = cached_style_for_color(struct[:color])
          struct[:formatted_open] = "  ╭─ #{struct[:icon]} " + "─" * 22
          result << struct
          i += 1
        when :callout_body
          bar_style   = cached_style_for_color(struct[:color])
          wrap_width  = [width - 6, 1].max  # "  │  " = 5 + 1 right margin
          wrap_runs(struct[:runs], wrap_width).each do |line_runs|
            result << { type: :callout_body, runs: line_runs, bar_style: bar_style }
          end
          i += 1
        when :callout_close
          struct[:bar_style]       = cached_style_for_color(struct[:color])
          struct[:formatted_close] = "  ╰" + "─" * 27
          result << struct
          i += 1
        when :table_row
          rows = []
          seps = []
          j    = i
          while j < structs.length
            case structs[j][:type]
            when :table_row then rows << structs[j]
            when :table_sep then seps << structs[j]
            else break
            end
            j += 1
          end

          col_count   = rows.map { |r| r[:cells].length }.max || 0
          sep_total   = [col_count - 1, 0].max * 3  # " │ " between cols
          max_col_w   = [(width - 2 - sep_total) / [col_count, 1].max, 10].max
          col_widths  = Array.new(col_count, 1)
          rows.each do |row|
            row[:cells].each_with_index do |cell, ci|
              w = [display_width(cell.empty? ? "—" : cell), max_col_w].min
              col_widths[ci] = [col_widths[ci], w].max
            end
          end

          rows.each do |row|
            row[:padded_cells] = Array.new(col_count) do |ci|
              raw = row[:cells][ci] || ""
              txt = raw.empty? ? "—" : raw
              pad_to_dw(truncate_to_dw(txt, max_col_w), col_widths[ci])
            end
            row[:formatted_content] = "  " + row[:padded_cells].join(" │ ")
          end

          sep_str = "  " + col_widths.map { |w| "─" * w }.join("─┼─")
          seps.each { |sep| sep[:formatted_sep] = sep_str }

          result.concat(structs[i...j])
          i = j
        else
          result << struct
          i += 1
        end
      end
      result
    end

    def wrap_runs(runs, max_width)
      return [runs] if max_width <= 0

      chars  = runs.flat_map { |run| run[:text].each_char.map { |c| { c: c, run: run } } }
      lines  = []
      buf    = []
      buf_w  = 0
      i      = 0

      while i < chars.length
        c  = chars[i][:c]
        cw = char_width(c)

        if buf_w + cw > max_width && !buf.empty?
          sp = buf.rindex { |e| e[:c] == ' ' }
          if sp && sp > 0
            overflow = buf[(sp + 1)..]
            lines << reconstruct_runs(buf[0, sp])
            buf   = overflow
            buf_w = buf.sum { |e| char_width(e[:c]) }
          else
            lines << reconstruct_runs(buf)
            buf   = []
            buf_w = 0
          end
        else
          buf   << chars[i]
          buf_w += cw
          i     += 1
        end
      end

      lines << reconstruct_runs(buf) unless buf.empty?
      lines.empty? ? [runs] : lines
    end

    def reconstruct_runs(char_entries)
      return [] if char_entries.empty?
      result   = []
      prev_run = char_entries.first[:run]
      buf      = +""
      char_entries.each do |e|
        if e[:run].equal?(prev_run)
          buf << e[:c]
        else
          result << prev_run.merge(text: buf)
          prev_run = e[:run]
          buf      = +e[:c]
        end
      end
      result << prev_run.merge(text: buf)
      result
    end

    def wide_char?(c)
      o = c.ord
      (o >= 0x1100 && o <= 0x115F)   ||  # Hangul Jamo
      (o >= 0x2E80 && o <= 0x303E)   ||  # CJK Radicals, Kangxi
      (o >= 0x3040 && o <= 0x33FF)   ||  # Hiragana, Katakana, CJK symbols
      (o >= 0x3400 && o <= 0x4DBF)   ||  # CJK Extension A
      (o >= 0x4E00 && o <= 0xA4C6)   ||  # CJK Unified Ideographs
      (o >= 0xA960 && o <= 0xA97C)   ||  # Hangul Jamo Extended-A
      (o >= 0xAC00 && o <= 0xD7A3)   ||  # Hangul Syllables
      (o >= 0xF900 && o <= 0xFAFF)   ||  # CJK Compatibility
      (o >= 0xFE10 && o <= 0xFE6B)   ||  # Vertical/Compatibility Forms
      (o >= 0xFF01 && o <= 0xFF60)   ||  # Fullwidth ASCII
      (o >= 0xFFE0 && o <= 0xFFE6)       # Fullwidth Signs
    end

    def char_width(c)
      wide_char?(c) ? 2 : 1
    end

    def display_width(str)
      str.each_char.sum { |c| char_width(c) }
    end

    def truncate_to_dw(str, max_dw)
      w = 0
      result = +""
      str.each_char do |c|
        cw = char_width(c)
        if w + cw > max_dw - 1
          result << "…"
          return result
        end
        result << c
        w += cw
      end
      result
    end

    def pad_to_dw(str, target_dw)
      str + " " * [target_dw - display_width(str), 0].max
    end
  end
end
