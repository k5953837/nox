# frozen_string_literal: true

require_relative "test_helper"
require "nox"

# Renders the roulette popup against the test backend and asserts the screen
# content — covers render_roulette_menu, which the pure scoring tests can't.
class RouletteRenderTest < Minitest::Test
  include RatatuiRuby::TestHelper

  WIDTH  = 80
  HEIGHT = 24

  def fake_data
    {
      order: ["Adora Xu", "Lin CJ", "Galen Lin", "Hsiao Jimmy"],
      weights: { a: 0.4, fr: 0.3, ft: 0.3 },
      recommendation: "Adora Xu",
      results: [
        { name: "Adora Xu",    user_id: "a", prob: 0.42, a: 1.0, fr: 0.95, ft: 0.5, reason: "負載輕(54.0pts)" },
        { name: "Lin CJ",      user_id: "c", prob: 0.33, a: 0.8, fr: 1.0,  ft: 0.5, reason: "綜合居中" },
        { name: "Galen Lin",   user_id: "g", prob: 0.20, a: 0.7, fr: 0.64, ft: 0.5, reason: "綜合居中" },
        { name: "Hsiao Jimmy", user_id: "j", prob: 0.05, a: 0.0, fr: 0.0,  ft: 0.5, reason: "綜合居中" },
      ],
    }
  end

  def fake_task
    Nox::Task.new(id: "t1", title: "Fix webhook retry", status: "Not started",
                  priority: "P2🟡 - 5wd", owners: [], url: "https://notion.so/t1",
                  completion_time: nil, updated_at: "2026-06-01T00:00:00.000Z")
  end

  def build_app(phase:, winner: nil)
    app = Nox::App.new
    app.instance_variable_set(:@tui, RatatuiRuby::TUI.new)
    app.send(:init_styles)
    app.instance_variable_set(:@board, Nox::Board.new([fake_task]))
    ls = RatatuiRuby::ListState.new(nil)
    ls.select(0)
    app.instance_variable_set(:@list_state, ls)
    app.instance_variable_set(:@roulette_data, fake_data)
    app.instance_variable_set(:@roulette_phase, phase)
    app.instance_variable_set(:@roulette_winner, winner)
    app.instance_variable_set(:@roulette_highlight, 0)
    app.instance_variable_set(:@mode, :roulette_menu)
    app
  end

  def screen
    (0...HEIGHT).map { |y| (0...WIDTH).map { |x| RatatuiRuby.get_cell_at(x, y).symbol }.join }.join("\n")
  end

  def test_ready_popup_renders_candidates_odds_and_weights
    with_test_terminal(WIDTH, HEIGHT) do
      app = build_app(phase: :ready)
      RatatuiRuby.draw { |f| app.send(:render, f) }
      s = screen
      ["Adora Xu", "Lin CJ", "Galen Lin", "Hsiao Jimmy"].each { |n| assert_includes s, n }
      assert_includes s, "42.0%"  # odds bar label
      assert_includes s, "0.40"   # weights line (可用 0.40)
      assert_includes s, "Space"  # ready-phase hint
    end
  end

  def test_revealed_popup_renders_winner_and_assign_hint
    with_test_terminal(WIDTH, HEIGHT) do
      app = build_app(phase: :revealed, winner: "Galen Lin")
      RatatuiRuby.draw { |f| app.send(:render, f) }
      s = screen
      assert_includes s, "Galen Lin"
      assert_includes s, "Enter"  # "Enter 指派" assign hint only shows when revealed
    end
  end
end
