# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/nox/roulette"

class RouletteTest < Minitest::Test
  R = Nox::Roulette

  def aggs
    [
      { name: "Adora Xu",    user_id: "a", open_pts: 87,  recent: 10, dom: { "外部渠道與系統整合" => 4 }, type: {} },
      { name: "Lin CJ",      user_id: "c", open_pts: 125, recent: 8,  dom: { "外部渠道與系統整合" => 3 }, type: {} },
      { name: "Galen Lin",   user_id: "g", open_pts: 151, recent: 22, dom: { "外部渠道與系統整合" => 9 }, type: {} },
      { name: "Hsiao Jimmy", user_id: "j", open_pts: 341, recent: 47, dom: { "外部渠道與系統整合" => 3 }, type: {} },
    ]
  end

  def test_minmax_and_inverse
    assert_equal [0.0, 0.5, 1.0], R.minmax([10, 20, 30])
    assert_equal [0.5, 0.5, 0.5], R.minmax([5, 5, 5])
    assert_equal [1.0, 0.5, 0.0], R.minmax_inv([10, 20, 30])
  end

  def test_weights_by_priority
    assert_equal({ a: 0.5, fr: 0.1, ft: 0.4 }, R.weights_for("P1🔴 - 8hr"))
    assert_equal({ a: 0.5, fr: 0.1, ft: 0.4 }, R.weights_for("P0🔥 - 4hr"))
    assert_equal({ a: 0.3, fr: 0.5, ft: 0.2 }, R.weights_for("Low"))
    assert_equal({ a: 0.4, fr: 0.3, ft: 0.3 }, R.weights_for("High"))
    assert_equal({ a: 0.4, fr: 0.3, ft: 0.3 }, R.weights_for(nil))
  end

  def test_fit_raw_counts_domain_overlap
    assert_equal [4.0, 3.0, 9.0, 3.0], R.fit_raw(["外部渠道與系統整合"], aggs)
  end

  def test_type_does_not_affect_fit
    # ticket 類型 was dropped from fit. Even though candidate A has 5 "Story"
    # tasks and B has none, a Story task with no domain stays neutral for both.
    a = [
      { name: "A", user_id: "a", open_pts: 10, recent: 1, dom: {}, type: { "Story" => 5 } },
      { name: "B", user_id: "b", open_pts: 10, recent: 1, dom: {}, type: { "Story" => 0 } },
    ]
    res = R.score(aggregates: a, task: { priority: "High", domains: [], type: "Story" })
    res[:results].each { |r| assert_equal 0.5, r[:ft] }
  end

  def test_probs_sum_to_one
    res = R.score(aggregates: aggs, task: { priority: "P1🔴 - 8hr", domains: ["外部渠道與系統整合"], type: nil })
    assert_in_delta 1.0, res[:results].sum { |r| r[:prob] }, 1e-3
  end

  def test_p1_integration_task_favors_domain_expert
    res = R.score(aggregates: aggs, task: { priority: "P1🔴 - 8hr", domains: ["外部渠道與系統整合"], type: nil })
    assert_equal "Galen Lin", res[:recommendation]
    assert_equal "Hsiao Jimmy", res[:results].last[:name]
    assert_equal({ a: 0.5, fr: 0.1, ft: 0.4 }, res[:weights])
    assert res[:results].first[:user_id], "winner must carry a user_id for write-back"
  end

  def test_neutral_fit_when_task_has_no_tags
    res = R.score(aggregates: aggs, task: { priority: nil, domains: [], type: nil })
    assert_equal "Adora Xu", res[:recommendation]
    res[:results].each { |r| assert_equal 0.5, r[:ft] }
  end

  def test_infer_domains_from_title
    assert_equal ["外部渠道與系統整合"], R.infer_domains("Omnichat 串接失敗")
    assert_includes R.infer_domains("AI 腳本推理邏輯錯誤"), "AI 腳本與推理邏輯"
    assert_equal [], R.infer_domains("某客戶月報整理")          # no domain keyword -> no guess
    assert_equal [], R.infer_domains(nil)
  end

  def test_infer_domains_ascii_word_boundary
    # the keyword "line" must not match inside "online" / "deadline"
    assert_equal [], R.infer_domains("online dashboard deadline")
  end

  def test_temperature_controls_peakiness
    low  = R.softmax([1.0, 0.5], 0.1)
    high = R.softmax([1.0, 0.5], 1.0)
    assert low[0] > high[0]
    assert_in_delta 1.0, low.sum,  1e-9
    assert_in_delta 1.0, high.sum, 1e-9
  end

  # Fake task responding to the bits evaluate/aggregate use.
  FT = Struct.new(:owner_names, :owners, :status, :points, :created_at, :domains, :type)

  def test_evaluate_filters_unresolved_owners_and_returns_order
    task  = Struct.new(:priority, :domains, :title).new("High", [], "月報整理") # title has no domain keyword
    # Hsiao Jimmy intentionally absent from the workspace users.
    users = [{ id: "a", name: "Adora Xu" }, { id: "c", name: "Lin CJ" }, { id: "g", name: "Galen Lin" }]
    sprint = [
      FT.new(["Adora Xu"],  [1], "In Progress", 5, "2026-06-20", [], nil),
      FT.new(["Galen Lin"], [1], "In Progress", 8, "2026-06-20", [], nil),
    ]
    history = { "Adora Xu" => [FT.new(["Adora Xu"], [1], "Done", 0, "2025-01-01", ["介面操作異常"], "Bug")] }
    res = R.evaluate(sprint_tasks: sprint, history_by_name: history, task: task,
                     users: users, today: Date.new(2026, 6, 22))

    assert_equal ["Adora Xu", "Lin CJ", "Galen Lin"], res[:order]
    assert_equal ["Hsiao Jimmy"], res[:missing]
    assert_equal 3, res[:results].size
    assert res[:results].all? { |r| r[:user_id] }, "every scored owner must have a user_id"
    assert_includes res[:order], res[:recommendation]
  end

  def four_users
    [{ id: "a", name: "Adora Xu" }, { id: "c", name: "Lin CJ" },
     { id: "g", name: "Galen Lin" }, { id: "j", name: "Hsiao Jimmy" }]
  end

  def test_evaluate_infers_domain_when_untagged
    task = Struct.new(:priority, :domains, :title).new("High", [], "Omnichat 串接失敗")
    res = R.evaluate(sprint_tasks: [], history_by_name: {}, task: task, users: four_users, today: Date.new(2026, 6, 22))
    assert_equal ["外部渠道與系統整合"], res[:effective_domains]
    assert_equal true, res[:domain_inferred]
  end

  def test_evaluate_real_domain_beats_title_inference
    # real domain set -> title is ignored, not flagged inferred
    task = Struct.new(:priority, :domains, :title).new("High", ["AI 知識庫與檢索"], "Omnichat 串接失敗")
    res = R.evaluate(sprint_tasks: [], history_by_name: {}, task: task, users: four_users, today: Date.new(2026, 6, 22))
    assert_equal ["AI 知識庫與檢索"], res[:effective_domains]
    assert_equal false, res[:domain_inferred]
  end

  def test_aggregate_splits_sprint_points_and_reads_fit_from_history
    t = Struct.new(:owners, :status, :points, :created_at, :domains, :type)
    # load/rotation come from the sprint list (note: no domains here)
    sprint = [
      t.new([1, 2], "In Progress", 8, "2026-06-20", [], nil), # 8/2 = 4 pts
      t.new([1],    "Done",        5, "2026-06-20", [], nil),  # closed -> 0
    ]
    # fit comes from the full-history list
    history = [
      t.new([1], "Done", 0, "2025-01-01", ["介面操作異常"], "Bug"),
      t.new([1], "Done", 0, "2025-02-01", ["介面操作異常"], nil),
    ]
    agg = R.aggregate("X", "x", sprint, history, Date.new(2026, 6, 22))
    assert_in_delta 4.0, agg[:open_pts], 1e-6      # load = current sprint
    assert_equal 2, agg[:dom]["介面操作異常"]        # fit = full history
  end
end
