# frozen_string_literal: true

require_relative "test_helper"
require "nox/shadow_grid"

class ShadowGridTest < Minitest::Test
  def setup
    @grid = Nox::ShadowGrid.new(20, 5)
  end

  # ── write / slice ────────────────────────────────────────────────────────

  def test_slice_of_untouched_cells_is_spaces
    assert_equal "    ", @grid.slice(0, 3, 0)
  end

  def test_write_then_slice_roundtrip
    @grid.write(2, 1, "hello")
    assert_equal "hello", @grid.slice(2, 6, 1)
  end

  def test_slice_clamps_out_of_bounds_coords
    @grid.write(15, 2, "abcde") # 截到 x=19
    assert_equal "abcde"[0, 5], @grid.slice(15, 99, 2)
    assert_equal "", @grid.slice(0, 19, 99)
  end

  def test_write_clips_to_max_width
    @grid.write(0, 0, "abcdef", max_width: 3)
    assert_equal "abc ", @grid.slice(0, 3, 0)
  end

  # ── 寬字元 ───────────────────────────────────────────────────────────────

  def test_wide_chars_occupy_two_cells_and_slice_intact
    @grid.write(1, 0, "修復ok")
    assert_equal "修復ok", @grid.slice(1, 6, 0)
  end

  def test_slice_starting_on_continuation_cell_drops_the_half_char
    @grid.write(0, 0, "修x")
    assert_equal "x", @grid.slice(1, 2, 0) # x=1 是「修」的後半格
  end

  def test_wide_char_not_written_when_only_one_cell_remains
    @grid.write(0, 0, "ab修", max_width: 3) # 「修」需 2 格但只剩 1 格
    assert_equal "ab ", @grid.slice(0, 2, 0)
  end

  # ── overlay segments(未觸碰 cell 與真實空白的區別)──────────────────────

  def test_segments_split_on_untouched_cells
    @grid.write(1, 0, "ab cd") # 內含真實空白
    @grid.write(10, 0, "ef")
    segments = @grid.segments(0, 12, 0)
    assert_equal [[1, "ab cd"], [10, "ef"]], segments
  end

  def test_segments_empty_for_untouched_row
    assert_empty @grid.segments(0, 19, 3)
  end

  def test_segments_starting_on_continuation_cell_anchors_at_next_real_char
    @grid.write(5, 0, "修ab") # 修 占 col 5-6,a 在 7,b 在 8
    # 選取左緣落在「修」的後半格(col 6) → 區段應從 col 7 的真實字元開始,
    # 否則 overlay 會把 "ab" 畫到 col 6,整段左移一格。
    assert_equal [[7, "ab"]], @grid.segments(6, 8, 0)
  end

  def test_segments_keeps_wide_char_run_start_when_fully_inside
    @grid.write(5, 0, "修ab")
    assert_equal [[5, "修ab"]], @grid.segments(5, 8, 0)
  end

  # ── clear_region ─────────────────────────────────────────────────────────

  def test_clear_region_resets_cells_to_untouched
    @grid.write(0, 1, "abcdef")
    @grid.clear_region(2, 1, 3, 1)
    assert_equal "ab   f", @grid.slice(0, 5, 1)
    assert_equal [[0, "ab"], [5, "f"]], @grid.segments(0, 9, 1)
  end

  # ── record(widget 內省)──────────────────────────────────────────────────

  def test_record_paragraph_with_border_and_title
    tui = RatatuiRuby::TUI.new
    para = tui.paragraph(
      text: "body",
      block: tui.block(title: " T ", borders: [:all])
    )
    area = RatatuiRuby::Layout::Rect.new(x: 0, y: 0, width: 10, height: 4)
    @grid.record(para, area)

    assert_equal " T ", @grid.slice(1, 3, 0)   # title 在上邊框列 x+1
    assert_equal "body", @grid.slice(1, 4, 1)  # 內容避開邊框
  end

  def test_record_paragraph_with_line_array
    tui = RatatuiRuby::TUI.new
    lines = [
      tui.text_line(spans: [tui.text_span(content: "ab"), tui.text_span(content: "cd")]),
      tui.text_line(spans: [tui.text_span(content: "ef")]),
    ]
    para = tui.paragraph(text: lines)
    area = RatatuiRuby::Layout::Rect.new(x: 2, y: 1, width: 10, height: 3)
    @grid.record(para, area)

    assert_equal "abcd", @grid.slice(2, 5, 1)
    assert_equal "ef", @grid.slice(2, 3, 2)
  end

  def test_record_list_with_offset_and_highlight_indent
    tui = RatatuiRuby::TUI.new
    items = %w[zero one two three four].map { |t| tui.text_line(spans: [tui.text_span(content: t)]) }
    list = tui.list(
      items: items,
      highlight_symbol: "▸ ",
      highlight_spacing: :always,
      block: tui.block(borders: [:all])
    )
    state = Struct.new(:offset).new(2) # duck-typed:record 只讀 .offset
    area = RatatuiRuby::Layout::Rect.new(x: 0, y: 0, width: 12, height: 4)
    @grid.record(list, area, state)

    # 邊框內第一列 = items[offset=2] = "two",highlight indent 2 格
    assert_equal "two", @grid.slice(3, 7, 1).rstrip
    # 邊框內高度 2,只顯示 items[2..3]
    assert_equal "three", @grid.slice(3, 7, 2).rstrip
    assert_equal "", @grid.slice(3, 7, 3).rstrip
  end

  def test_record_clear_wipes_region
    @grid.write(0, 0, "abcdefgh")
    clear = RatatuiRuby::TUI.new.clear
    area = RatatuiRuby::Layout::Rect.new(x: 2, y: 0, width: 4, height: 1)
    @grid.record(clear, area)

    assert_equal [[0, "ab"], [6, "gh"]], @grid.segments(0, 9, 0)
  end

  def test_record_ignores_unknown_widgets
    @grid.record(Object.new, RatatuiRuby::Layout::Rect.new(x: 0, y: 0, width: 5, height: 2))
    assert_empty @grid.segments(0, 19, 0)
  end
end
