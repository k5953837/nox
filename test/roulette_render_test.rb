# frozen_string_literal: true

require_relative "test_helper"
require "nox"

# Renders the auto-assign popup against the test backend and asserts the screen
# content — covers render_roulette_menu, which the pure scoring tests can't.
class RouletteRenderTest < Minitest::Test
  include RatatuiRuby::TestHelper

  WIDTH  = 80
  HEIGHT = 24

  # Pre-sorted by score (desc) — Adora is the recommendation (argmax).
  def fake_data
    {
      order: ["Adora Xu", "Lin CJ", "Galen Lin", "Hsiao Jimmy"],
      weights: { a: 0.4, fr: 0.3, ft: 0.3 },
      recommendation: "Adora Xu",
      results: [
        { name: "Adora Xu",    user_id: "a", prob: 0.42, a: 1.0, fr: 0.95, ft: 0.5, reason: "load light" },
        { name: "Lin CJ",      user_id: "c", prob: 0.33, a: 0.8, fr: 1.0,  ft: 0.5, reason: "fresh" },
        { name: "Galen Lin",   user_id: "g", prob: 0.20, a: 0.7, fr: 0.64, ft: 0.5, reason: "mid" },
        { name: "Hsiao Jimmy", user_id: "j", prob: 0.05, a: 0.0, fr: 0.0,  ft: 0.5, reason: "swamped" },
      ],
    }
  end

  def fake_task
    Nox::Task.new(id: "t1", title: "Fix webhook retry", status: "Not started",
                  priority: "P2", owners: [], url: "https://notion.so/t1",
                  completion_time: nil, updated_at: "2026-06-01T00:00:00.000Z")
  end

  def build_app(winner: "Adora Xu")
    app = Nox::App.new
    app.instance_variable_set(:@tui, RatatuiRuby::TUI.new)
    app.send(:init_styles)
    app.instance_variable_set(:@board, Nox::Board.new([fake_task]))
    ls = RatatuiRuby::ListState.new(nil)
    ls.select(0)
    app.instance_variable_set(:@list_state, ls)
    app.instance_variable_set(:@roulette_data, fake_data)
    app.instance_variable_set(:@roulette_winner, winner)
    app.instance_variable_set(:@mode, :roulette_menu)
    app
  end

  def screen
    (0...HEIGHT).map { |y| (0...WIDTH).map { |x| RatatuiRuby.get_cell_at(x, y).symbol }.join }.join("\n")
  end

  def test_popup_renders_ranked_candidates_odds_and_weights
    with_test_terminal(WIDTH, HEIGHT) do
      app = build_app
      RatatuiRuby.draw { |f| app.send(:render, f) }
      s = screen
      ["Adora Xu", "Lin CJ", "Galen Lin", "Hsiao Jimmy"].each { |n| assert_includes s, n }
      assert_includes s, "42.0%"  # odds bar label
      assert_includes s, "0.40"   # weights line
      assert_includes s, "▶"      # the recommendation marker
    end
  end

  def test_enter_hint_names_the_recommendation
    with_test_terminal(WIDTH, HEIGHT) do
      app = build_app(winner: "Adora Xu")
      RatatuiRuby.draw { |f| app.send(:render, f) }
      s = screen
      assert_includes s, "Adora Xu"
      assert_includes s, "Enter"  # "Enter 指派 Adora Xu …"
    end
  end

  def test_help_view_renders_metric_explanation
    with_test_terminal(WIDTH, HEIGHT) do
      app = build_app
      app.instance_variable_set(:@roulette_help, true)
      RatatuiRuby.draw { |f| app.send(:render, f) }
      s = screen
      assert_includes s, "softmax"          # the combine formula
      assert_includes s, "0.5 / 0.1 / 0.4"  # P0/P1 weights row
    end
  end
end
