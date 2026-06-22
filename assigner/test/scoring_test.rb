# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/scoring"

class ScoringTest < Minitest::Test
  S = Assigner::Scoring

  # Real-data-shaped aggregates (non-split pts; values from live probe).
  def aggs
    [
      { name: "Adora", user_id: "a", open_pts: 87,  recent: 10, dom: { "外部渠道與系統整合" => 4 }, type: {} },
      { name: "LinCJ", user_id: "c", open_pts: 125, recent: 8,  dom: { "外部渠道與系統整合" => 3 }, type: {} },
      { name: "Galen", user_id: "g", open_pts: 151, recent: 22, dom: { "外部渠道與系統整合" => 9 }, type: {} },
      { name: "Jimmy", user_id: "j", open_pts: 341, recent: 47, dom: { "外部渠道與系統整合" => 3 }, type: {} },
    ]
  end

  def test_minmax_basic
    assert_equal [0.0, 0.5, 1.0], S.minmax([10, 20, 30])
  end

  def test_minmax_all_equal_is_neutral
    assert_equal [0.5, 0.5, 0.5], S.minmax([5, 5, 5])
  end

  def test_minmax_inv_flips
    assert_equal [1.0, 0.5, 0.0], S.minmax_inv([10, 20, 30])
  end

  def test_weights_by_priority
    assert_equal({ a: 0.5, fr: 0.1, ft: 0.4 }, S.weights_for("P1🔴 - 8hr"))
    assert_equal({ a: 0.5, fr: 0.1, ft: 0.4 }, S.weights_for("P0🔥 - 4hr"))
    assert_equal({ a: 0.3, fr: 0.5, ft: 0.2 }, S.weights_for("Low"))
    assert_equal({ a: 0.4, fr: 0.3, ft: 0.3 }, S.weights_for("High"))
    assert_equal({ a: 0.4, fr: 0.3, ft: 0.3 }, S.weights_for(nil))
  end

  def test_fit_raw_counts_domain_overlap
    raw = S.fit_raw(["外部渠道與系統整合"], nil, aggs)
    assert_equal [4.0, 3.0, 9.0, 3.0], raw
  end

  def test_probs_sum_to_one
    res = S.score(aggregates: aggs, task: { priority: "P1🔴 - 8hr", domains: ["外部渠道與系統整合"], type: nil })
    total = res[:results].sum { |r| r[:prob] }
    assert_in_delta 1.0, total, 1e-3
  end

  def test_p1_integration_task_favors_domain_expert
    res = S.score(aggregates: aggs, task: { priority: "P1🔴 - 8hr", domains: ["外部渠道與系統整合"], type: nil })
    assert_equal "Galen", res[:recommendation] # most 外部整合 history + decent availability
    assert_equal "Jimmy", res[:results].last[:name] # swamped -> lowest
    assert_equal({ a: 0.5, fr: 0.1, ft: 0.4 }, res[:weights])
  end

  def test_neutral_fit_when_task_has_no_tags
    res = S.score(aggregates: aggs, task: { priority: nil, domains: [], type: nil })
    # fit cancels -> load + rotation decide -> lightest+fresh Adora wins
    assert_equal "Adora", res[:recommendation]
    res[:results].each { |r| assert_equal 0.5, r[:ft] }
  end

  def test_temperature_controls_peakiness
    low  = S.softmax([1.0, 0.5], 0.1)
    high = S.softmax([1.0, 0.5], 1.0)
    assert low[0] > high[0], "lower temperature should be more decisive"
    assert_in_delta 1.0, low.sum,  1e-9
    assert_in_delta 1.0, high.sum, 1e-9
  end
end
