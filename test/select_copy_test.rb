# frozen_string_literal: true

require_relative "test_helper"
require "nox"

# 滑鼠矩形選取複製的整合測試:
# 注入 down/drag/up 滑鼠事件 → 驗證 overlay 反白與 clipboard 內容。
class SelectCopyTest < Minitest::Test
  include RatatuiRuby::TestHelper

  WIDTH  = 80
  HEIGHT = 24

  def fake_tasks
    mk = lambda do |id, title, status|
      Nox::Task.new(
        id: id, title: title, status: status, priority: nil,
        owners: [{ id: "u1", name: "kit" }], url: "https://notion.so/#{id}",
        completion_time: nil, updated_at: "2026-06-01T00:00:00.000Z"
      )
    end
    [
      mk.call("t1", "Fix login flow", "In Progress"),
      mk.call("t2", "Deploy beta", "Not started"),
      mk.call("t3", "修復登入流程", "Not started")
    ]
  end

  def build_app(clipboard:)
    app = Nox::App.new(clipboard: clipboard)
    app.instance_variable_set(:@tui, RatatuiRuby::TUI.new)
    app.send(:init_styles)
    app.instance_variable_set(:@board, Nox::Board.new(fake_tasks))
    list_state = RatatuiRuby::ListState.new(nil)
    list_state.select(0)
    app.instance_variable_set(:@list_state, list_state)
    owner_state = RatatuiRuby::ListState.new(nil)
    owner_state.select(0)
    app.instance_variable_set(:@owner_list_state, owner_state)
    app.instance_variable_set(:@current_sprint, { name: "Sprint 42" })
    app.instance_variable_set(:@mode, :board)
    app
  end

  # draw 一幀 + 處理一個事件(模擬主迴圈一輪)
  def step(app)
    RatatuiRuby.draw { |f| app.send(:render, f) }
    app.send(:handle_event, RatatuiRuby.poll_event)
  end

  def row_text(y, x1 = 0, x2 = WIDTH - 1)
    (x1..x2).map { |x| RatatuiRuby.get_cell_at(x, y).symbol }.join
  end

  def find_row(marker)
    (0...HEIGHT).find { |y| row_text(y).include?(marker) } ||
      flunk("marker #{marker.inspect} not found on screen")
  end

  def drag_select(app, from_x, from_y, to_x, to_y)
    inject_mouse(x: from_x, y: from_y, kind: :down)
    step(app)
    inject_mouse(x: to_x, y: to_y, kind: :drag)
    step(app)
    inject_mouse(x: to_x, y: to_y, kind: :up)
    step(app)
  end

  # ── 複製管線 ─────────────────────────────────────────────────────────────

  def test_drag_copies_selected_text
    with_test_terminal(WIDTH, HEIGHT) do
      copied = []
      app = build_app(clipboard: ->(t) { copied << t })
      step(app)

      y = find_row("Fix login flow")
      x = row_text(y).index("Fix login flow")
      drag_select(app, x, y, x + 13, y)

      assert_equal ["Fix login flow"], copied
    end
  end

  def test_multi_row_drag_joins_lines_with_newline
    with_test_terminal(WIDTH, HEIGHT) do
      copied = []
      app = build_app(clipboard: ->(t) { copied << t })
      step(app)

      ya = find_row("Fix login flow")
      yb = find_row("Deploy beta")
      y_top, y_bot = [ya, yb].minmax
      x = row_text(ya).index("Fix login flow")
      drag_select(app, x, y_top, x + 5, y_bot)

      assert_equal 1, copied.length
      lines = copied.first.split("\n", -1)
      assert_equal (y_bot - y_top + 1), lines.length
      top_title, bot_title = ya < yb ? ["Fix lo", "Deploy"] : ["Deploy", "Fix lo"]
      assert_equal top_title, lines.first
      assert_equal bot_title, lines.last
      lines.each { |l| assert_equal l.rstrip, l, "lines must be right-trimmed" }
    end
  end

  def test_backward_drag_equals_forward_drag
    with_test_terminal(WIDTH, HEIGHT) do
      copied = []
      app = build_app(clipboard: ->(t) { copied << t })
      step(app)

      y = find_row("Fix login flow")
      x = row_text(y).index("Fix login flow")
      drag_select(app, x + 13, y, x, y)

      assert_equal ["Fix login flow"], copied
    end
  end

  def test_cjk_text_copies_intact
    with_test_terminal(WIDTH, HEIGHT) do
      copied = []
      app = build_app(clipboard: ->(t) { copied << t })
      step(app)

      y = find_row("修")
      x = row_text(y).index("修")
      drag_select(app, x, y, x + 11, y) # 6 個全形字 × 2 cells

      assert_equal 1, copied.length
      assert_includes copied.first, "修復登入流程"
    end
  end

  # ── 防誤觸與既有行為 ─────────────────────────────────────────────────────

  def test_single_click_does_not_copy_and_still_selects_row
    with_test_terminal(WIDTH, HEIGHT) do
      copied = []
      app = build_app(clipboard: ->(t) { copied << t })
      step(app)

      y = find_row("Deploy beta")
      x = row_text(y).index("Deploy beta")
      inject_mouse(x: x, y: y, kind: :down)
      step(app)
      inject_mouse(x: x, y: y, kind: :up)
      step(app)

      assert_empty copied
      assert_equal "Deploy beta", app.send(:current_task).title
    end
  end

  def test_drag_back_to_anchor_does_not_copy
    with_test_terminal(WIDTH, HEIGHT) do
      copied = []
      app = build_app(clipboard: ->(t) { copied << t })
      step(app)

      y = find_row("Fix login flow")
      x = row_text(y).index("Fix login flow")
      inject_mouse(x: x, y: y, kind: :down)
      step(app)
      inject_mouse(x: x + 5, y: y, kind: :drag)
      step(app)
      inject_mouse(x: x, y: y, kind: :drag)
      step(app)
      inject_mouse(x: x, y: y, kind: :up)
      step(app)

      assert_empty copied
    end
  end

  def test_double_click_still_enters_detail
    with_test_terminal(WIDTH, HEIGHT) do
      app = build_app(clipboard: ->(_t) {})
      fake_client = Object.new
      def fake_client.fetch_page_content(_id) = []
      def fake_client.fetch_sub_tasks(_id) = []
      app.instance_variable_set(:@client, fake_client)
      step(app)

      y = find_row("Deploy beta")
      x = row_text(y).index("Deploy beta")
      2.times do
        inject_mouse(x: x, y: y, kind: :down)
        step(app)
        inject_mouse(x: x, y: y, kind: :up)
        step(app)
      end

      assert_equal :detail, app.instance_variable_get(:@mode)
    end
  end

  def test_scroll_still_moves_task_selection
    with_test_terminal(WIDTH, HEIGHT) do
      app = build_app(clipboard: ->(_t) {})
      step(app)

      y = find_row("Fix login flow")
      x = row_text(y).index("Fix login flow")
      board = app.instance_variable_get(:@board)
      assert_equal 0, board.current_row

      inject_mouse(x: x, y: y, kind: :scroll_down)
      step(app)

      assert_equal 1, board.current_row
    end
  end

  def test_click_after_drag_copy_is_not_double_click
    with_test_terminal(WIDTH, HEIGHT) do
      app = build_app(clipboard: ->(_t) {})
      detail_opened = false
      fake_client = Object.new
      fake_client.define_singleton_method(:fetch_page_content) do |_id|
        detail_opened = true
        []
      end
      fake_client.define_singleton_method(:fetch_sub_tasks) { |_id| [] }
      app.instance_variable_set(:@client, fake_client)
      step(app)

      y = find_row("Deploy beta")
      x = row_text(y).index("Deploy beta")
      drag_select(app, x, y, x + 5, y) # 拖曳複製(起手 down 落在同一格)
      inject_mouse(x: x, y: y, kind: :down) # 緊接著的單擊
      step(app)
      inject_mouse(x: x, y: y, kind: :up)
      step(app)

      refute detail_opened, "single click right after a drag-copy must not count as double-click"
    end
  end

  def test_scroll_clears_active_selection
    with_test_terminal(WIDTH, HEIGHT) do
      app = build_app(clipboard: ->(_t) {})
      step(app)

      y = find_row("Fix login flow")
      x = row_text(y).index("Fix login flow")
      inject_mouse(x: x, y: y, kind: :down)
      step(app)
      inject_mouse(x: x + 4, y: y, kind: :drag)
      step(app)
      inject_mouse(x: x, y: y, kind: :scroll_down)
      step(app)
      RatatuiRuby.draw { |f| app.send(:render, f) }

      (x..x + 4).each do |cx|
        refute RatatuiRuby.get_cell_at(cx, y).reversed?,
               "scroll must clear the selection overlay (cell #{cx},#{y})"
      end
    end
  end

  def test_key_event_clears_active_selection
    with_test_terminal(WIDTH, HEIGHT) do
      app = build_app(clipboard: ->(_t) {})
      step(app)

      y = find_row("Fix login flow")
      x = row_text(y).index("Fix login flow")
      inject_mouse(x: x, y: y, kind: :down)
      step(app)
      inject_mouse(x: x + 4, y: y, kind: :drag)
      step(app)
      inject_key("j")
      step(app)
      RatatuiRuby.draw { |f| app.send(:render, f) }

      (x..x + 4).each do |cx|
        refute RatatuiRuby.get_cell_at(cx, y).reversed?,
               "keyboard input must clear the selection overlay (cell #{cx},#{y})"
      end
    end
  end

  def test_overlay_with_out_of_bounds_rect_does_not_crash
    with_test_terminal(WIDTH, HEIGHT) do
      app = build_app(clipboard: ->(_t) {})
      step(app)

      y = find_row("Fix login flow")
      x = row_text(y).index("Fix login flow")

      # 模擬 resize 競態:選取座標超出目前 buffer(draw 先於 resize 事件處理)
      sel = app.instance_variable_get(:@selection)
      sel.start(0, 0, max_x: 200, max_y: 90)
      sel.update(150, 80)

      RatatuiRuby.draw { |f| app.send(:render, f) } # 不應 raise
      assert RatatuiRuby.get_cell_at(x, y).reversed?, "in-bounds part of the overlay still renders"
    end
  end

  # ── 生產環境契約:live Crossterm 上 get_cell_at 一律 raise ───────────────
  # (gem 的 buffer 讀回是 TestBackend 專用;選取功能不得依賴它)

  def test_select_copy_works_without_buffer_readback
    with_test_terminal(WIDTH, HEIGHT) do
      copied = []
      app = build_app(clipboard: ->(t) { copied << t })
      step(app)

      y = find_row("Fix login flow")
      x = row_text(y).index("Fix login flow")
      crossterm_contract = lambda do |*_args|
        raise RatatuiRuby::Error::Terminal, "Coordinates out of bounds"
      end

      RatatuiRuby.stub(:get_cell_at, crossterm_contract) do
        inject_mouse(x: x, y: y, kind: :down)
        step(app)
        inject_mouse(x: x + 13, y: y, kind: :drag)
        step(app)
        RatatuiRuby.draw { |f| app.send(:render, f) } # overlay 重繪
      end

      assert RatatuiRuby.get_cell_at(x, y).reversed?,
             "overlay must render without buffer read-back"

      RatatuiRuby.stub(:get_cell_at, crossterm_contract) do
        inject_mouse(x: x + 13, y: y, kind: :up)
        step(app)
      end

      assert_equal ["Fix login flow"], copied
    end
  end

  # ── 反白渲染 ─────────────────────────────────────────────────────────────

  def test_drag_shows_reversed_overlay
    with_test_terminal(WIDTH, HEIGHT) do
      app = build_app(clipboard: ->(_t) {})
      step(app)

      y = find_row("Fix login flow")
      x = row_text(y).index("Fix login flow")
      inject_mouse(x: x, y: y, kind: :down)
      step(app)
      inject_mouse(x: x + 4, y: y, kind: :drag)
      step(app)
      RatatuiRuby.draw { |f| app.send(:render, f) } # 套用 overlay 的重繪

      (x..x + 4).each do |cx|
        assert RatatuiRuby.get_cell_at(cx, y).reversed?, "cell #{cx},#{y} should be reversed"
      end
      refute RatatuiRuby.get_cell_at(x + 5, y).reversed?, "outside selection must not be reversed"
      # 字元不因 overlay 改變
      assert_equal "Fix l", row_text(y, x, x + 4)
    end
  end

  def test_overlay_cleared_after_copy
    with_test_terminal(WIDTH, HEIGHT) do
      app = build_app(clipboard: ->(_t) {})
      step(app)

      y = find_row("Fix login flow")
      x = row_text(y).index("Fix login flow")
      drag_select(app, x, y, x + 4, y)
      RatatuiRuby.draw { |f| app.send(:render, f) }

      (x..x + 4).each do |cx|
        refute RatatuiRuby.get_cell_at(cx, y).reversed?, "cell #{cx},#{y} should be back to normal"
      end
    end
  end

  def test_copy_shows_status_notice
    with_test_terminal(WIDTH, HEIGHT) do
      app = build_app(clipboard: ->(_t) {})
      step(app)

      y = find_row("Fix login flow")
      x = row_text(y).index("Fix login flow")
      drag_select(app, x, y, x + 13, y)
      RatatuiRuby.draw { |f| app.send(:render, f) }

      footer = row_text(HEIGHT - 1)
      assert_includes footer, "✓ copied 14 chars"
    end
  end

  def test_clipboard_failure_shows_error_notice
    with_test_terminal(WIDTH, HEIGHT) do
      app = build_app(clipboard: ->(_t) { raise IOError, "pbcopy gone" })
      step(app)

      y = find_row("Fix login flow")
      x = row_text(y).index("Fix login flow")
      drag_select(app, x, y, x + 13, y)
      RatatuiRuby.draw { |f| app.send(:render, f) }

      assert_includes row_text(HEIGHT - 1), "✗ copy failed"
    end
  end
end
