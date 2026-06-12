# frozen_string_literal: true

require_relative 'test_helper'
require 'nox/selection'

class SelectionTest < Minitest::Test
  def setup
    @sel = Nox::Selection.new
  end

  # ── 生命週期 ──────────────────────────────────────────────────────────────

  def test_inactive_by_default
    refute @sel.active?
  end

  def test_start_activates
    @sel.start(5, 3)
    assert @sel.active?
  end

  def test_clear_deactivates
    @sel.start(5, 3)
    @sel.clear
    refute @sel.active?
  end

  def test_rect_is_nil_when_inactive
    assert_nil @sel.rect
  end

  # ── rect 正規化 ──────────────────────────────────────────────────────────

  def test_rect_at_start_is_single_cell
    @sel.start(5, 3)
    assert_equal [5, 3, 5, 3], @sel.rect
  end

  def test_rect_after_forward_drag
    @sel.start(5, 3)
    @sel.update(10, 7)
    assert_equal [5, 3, 10, 7], @sel.rect
  end

  def test_rect_normalizes_backward_drag
    @sel.start(10, 7)
    @sel.update(5, 3)
    assert_equal [5, 3, 10, 7], @sel.rect
  end

  def test_rect_normalizes_mixed_direction_drag
    @sel.start(5, 7)
    @sel.update(10, 3)
    assert_equal [5, 3, 10, 7], @sel.rect
  end

  # ── clamp ────────────────────────────────────────────────────────────────

  def test_update_clamps_to_bounds
    @sel.start(5, 3, max_x: 79, max_y: 23)
    @sel.update(200, 100)
    assert_equal [5, 3, 79, 23], @sel.rect
  end

  def test_update_clamps_negative_coords_to_zero
    @sel.start(5, 3, max_x: 79, max_y: 23)
    @sel.update(-4, -2)
    assert_equal [0, 0, 5, 3], @sel.rect
  end

  def test_update_without_bounds_does_not_clamp
    @sel.start(5, 3)
    @sel.update(200, 100)
    assert_equal [5, 3, 200, 100], @sel.rect
  end

  # ── single_cell? 防誤觸 ──────────────────────────────────────────────────

  def test_single_cell_when_no_drag
    @sel.start(5, 3)
    assert @sel.single_cell?
  end

  def test_single_cell_when_dragged_back_to_anchor
    @sel.start(5, 3)
    @sel.update(10, 7)
    @sel.update(5, 3)
    assert @sel.single_cell?
  end

  def test_not_single_cell_after_drag
    @sel.start(5, 3)
    @sel.update(6, 3)
    refute @sel.single_cell?
  end

  # ── start 重設既有選取 ──────────────────────────────────────────────────

  def test_start_resets_previous_selection
    @sel.start(5, 3)
    @sel.update(10, 7)
    @sel.start(1, 1)
    assert_equal [1, 1, 1, 1], @sel.rect
  end
end
