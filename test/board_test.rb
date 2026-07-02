# frozen_string_literal: true

require_relative "test_helper"
require "nox/task"
require "nox/board"

class BoardTest < Minitest::Test
  def make_task(id:, title:, status: "In Progress", parent_id: nil, owners: [], updated_at: "2026-07-01T00:00:00.000Z")
    Nox::Task.new(
      id: id, title: title, status: status, priority: nil,
      owners: owners, url: nil, completion_time: nil,
      updated_at: updated_at, parent_id: parent_id
    )
  end

  def setup
    @parent = make_task(id: "p1", title: "ChargeSPOT 泰文 FAQ 未命中", updated_at: "2026-07-02T00:00:00.000Z")
    @sub    = make_task(id: "s1", title: "Neptune TokenizerFactory BM25 檢索失效", parent_id: "p1")
    @other  = make_task(id: "t1", title: "Owner density bar", updated_at: "2026-06-30T00:00:00.000Z")
    @board  = Nox::Board.new([@parent, @sub, @other])
  end

  # ── 預設視圖：root-only ──────────────────────────────────────────────────

  def test_default_view_excludes_sub_tasks
    refute_includes @board.filtered_tasks, @sub
    assert_includes @board.filtered_tasks, @parent
  end

  # ── 搜尋時納入子任務 ────────────────────────────────────────────────────

  def test_search_surfaces_matching_sub_tasks
    @board.search("tokenizer")
    assert_includes @board.filtered_tasks, @sub
  end

  def test_search_still_filters_non_matching_tasks
    @board.search("tokenizer")
    refute_includes @board.filtered_tasks, @parent
    refute_includes @board.filtered_tasks, @other
  end

  def test_clearing_search_hides_sub_tasks_again
    @board.search("tokenizer")
    @board.search("")
    refute_includes @board.filtered_tasks, @sub
  end

  def test_status_counts_include_sub_tasks_while_searching
    @board.search("tokenizer")
    assert_equal({ "In Progress" => 1 }, @board.status_counts)
  end
end
