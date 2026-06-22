# frozen_string_literal: true

module Assigner
  # The allocation engine — pure functions, zero I/O.
  # Everything here is unit-testable without touching Notion.
  module Scoring
    module_function

    # Min-max normalize to [0,1]. All-equal (incl. single) -> neutral 0.5.
    def minmax(vals)
      lo = vals.min
      hi = vals.max
      return Array.new(vals.size, 0.5) if hi.nil? || hi == lo
      vals.map { |v| (v - lo).to_f / (hi - lo) }
    end

    # Inverse: lower raw value -> higher score (used for load & recency).
    def minmax_inv(vals)
      minmax(vals).map { |v| 1.0 - v }
    end

    # Priority string -> factor weights (spec §5). Sliders may override.
    def weights_for(priority)
      case priority.to_s
      when /\AP[01]/ then { a: 0.5, fr: 0.1, ft: 0.4 } # P0/P1 urgent
      when /\ALow/i  then { a: 0.3, fr: 0.5, ft: 0.2 } # low -> fairness
      else                { a: 0.4, fr: 0.3, ft: 0.3 } # balanced
      end
    end

    # Raw fit per candidate: overlap of task tags with each candidate's history.
    def fit_raw(domains, type, aggregates)
      aggregates.map do |a|
        s = (domains || []).sum { |d| (a[:dom] && a[:dom][d]) || 0 }
        s += (a[:type] && a[:type][type]) || 0 if type
        s.to_f
      end
    end

    def softmax(scores, temperature)
      t = [temperature.to_f, 0.05].max # clamp so T->0 stays finite
      exps = scores.map { |s| Math.exp(s / t) }
      sum  = exps.reduce(0.0, :+)
      return Array.new(scores.size, 1.0 / scores.size) if sum <= 0
      exps.map { |e| e / sum }
    end

    # Main entry. aggregates: [{name,user_id,open_pts,recent,dom,type}]
    #             task:       {priority,domains,type}
    # Returns factor scores + probabilities + one-line reasons, ordered desc.
    def score(aggregates:, task:, weights: nil, temperature: 0.3)
      open_pts = aggregates.map { |a| a[:open_pts].to_f }
      recent   = aggregates.map { |a| a[:recent].to_f }

      a_arr  = minmax_inv(open_pts)
      fr_arr = minmax_inv(recent)
      fr_raw = fit_raw(task[:domains], task[:type], aggregates)
      ft_arr = (fr_raw.max && fr_raw.max > 0) ? minmax(fr_raw) : Array.new(aggregates.size, 0.5)

      w = weights || weights_for(task[:priority])
      scores = aggregates.each_index.map { |i| w[:a] * a_arr[i] + w[:fr] * fr_arr[i] + w[:ft] * ft_arr[i] }
      probs  = softmax(scores, temperature)

      results = aggregates.each_index.map do |i|
        {
          name:     aggregates[i][:name],
          user_id:  aggregates[i][:user_id],
          open_pts: open_pts[i],
          recent:   recent[i].to_i,
          fit_raw:  fr_raw[i],
          a:  round2(a_arr[i]),
          fr: round2(fr_arr[i]),
          ft: round2(ft_arr[i]),
          score: round2(scores[i]),
          prob:  round4(probs[i]),
          reason: reason_for(a_arr[i], fr_arr[i], ft_arr[i], aggregates[i], task),
        }
      end

      ordered = results.sort_by { |r| -r[:prob] }
      { weights: w, temperature: [temperature.to_f, 0.05].max, results: ordered,
        recommendation: ordered.first && ordered.first[:name] }
    end

    def reason_for(a, fr, ft, agg, task)
      bits = []
      bits << "負載輕（#{agg[:open_pts]}pts）" if a >= 0.66
      bits << "最近被指派少（#{agg[:recent]}）" if fr >= 0.66
      if ft >= 0.66 && !(task[:domains] || []).empty?
        matched = task[:domains] & (agg[:dom] ? agg[:dom].keys : [])
        bits << "領域契合（#{matched.join('、')}）" unless matched.empty?
      end
      bits.empty? ? "綜合居中" : bits.join("＋")
    end

    def round2(x)
      (x.to_f * 100).round / 100.0
    end

    def round4(x)
      (x.to_f * 10_000).round / 10_000.0
    end
  end
end
