# frozen_string_literal: true

require "date"

module Nox
  # Weighted task-assignment engine. Picks an owner for a task among a fixed
  # candidate set, with each candidate's probability driven by real Notion data:
  # current load, recent rotation, and domain fit — modulated by task priority.
  #
  # The scoring half is pure (no I/O) and unit-testable on its own. `evaluate`
  # is the only part that touches Notion (via Nox::Client).
  module Roulette
    module_function

    # Owners we allocate among. Names must match Notion `owner` people names.
    WEIGHTED_OWNERS = ["Adora Xu", "Lin CJ", "Galen Lin", "Hsiao Jimmy"].freeze

    # Terminal colours, one per candidate (kept distinct for the odds bars).
    COLORS = {
      "Adora Xu"    => :magenta,
      "Lin CJ"      => :cyan,
      "Galen Lin"   => :yellow,
      "Hsiao Jimmy" => :blue,
    }.freeze

    CLOSED = ["Done", "Archived"].freeze

    # ── pure scoring ──────────────────────────────────────────────────────────

    # Min-max normalize to [0,1]. All-equal (incl. single) -> neutral 0.5.
    def minmax(vals)
      lo = vals.min
      hi = vals.max
      return Array.new(vals.size, 0.5) if hi.nil? || hi == lo
      vals.map { |v| (v - lo).to_f / (hi - lo) }
    end

    # Lower raw value -> higher score (used for load & recency).
    def minmax_inv(vals)
      minmax(vals).map { |v| 1.0 - v }
    end

    # Priority string -> factor weights. Sliders/overrides may replace these.
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

    # aggregates: [{name,user_id,open_pts,recent,dom,type}]
    # task:       {priority,domains,type}
    def score(aggregates:, task:, weights: nil, temperature: 0.3)
      open_pts = aggregates.map { |a| a[:open_pts].to_f }
      recent   = aggregates.map { |a| a[:recent].to_f }

      a_arr  = minmax_inv(open_pts)
      fr_arr = minmax_inv(recent)
      raw    = fit_raw(task[:domains], task[:type], aggregates)
      ft_arr = (raw.max && raw.max > 0) ? minmax(raw) : Array.new(aggregates.size, 0.5)

      w = weights || weights_for(task[:priority])
      scores = aggregates.each_index.map { |i| w[:a] * a_arr[i] + w[:fr] * fr_arr[i] + w[:ft] * ft_arr[i] }
      probs  = softmax(scores, temperature)

      results = aggregates.each_index.map do |i|
        {
          name:     aggregates[i][:name],
          user_id:  aggregates[i][:user_id],
          open_pts: open_pts[i],
          recent:   recent[i].to_i,
          a:  round2(a_arr[i]),
          fr: round2(fr_arr[i]),
          ft: round2(ft_arr[i]),
          prob: round4(probs[i]),
          reason: reason_for(a_arr[i], fr_arr[i], ft_arr[i], aggregates[i], task),
        }
      end

      ordered = results.sort_by { |r| -r[:prob] }
      { weights: w, temperature: [temperature.to_f, 0.05].max, results: ordered,
        recommendation: ordered.first && ordered.first[:name] }
    end

    def reason_for(a, fr, ft, agg, task)
      bits = []
      bits << "負載輕(#{agg[:open_pts]}pts)" if a >= 0.66
      bits << "最近被指派少(#{agg[:recent]})" if fr >= 0.66
      if ft >= 0.66 && !(task[:domains] || []).empty?
        matched = task[:domains] & (agg[:dom] ? agg[:dom].keys : [])
        bits << "領域契合(#{matched.join('、')})" unless matched.empty?
      end
      bits.empty? ? "綜合居中" : bits.join("＋")
    end

    def round2(x)
      (x.to_f * 100).round / 100.0
    end

    def round4(x)
      (x.to_f * 10_000).round / 10_000.0
    end

    # ── aggregation + Notion I/O ────────────────────────────────────────────────

    # Build one aggregate from a candidate's owned Task list (multi-owner pts
    # are split across co-owners so load isn't double-counted).
    def aggregate(name, user_id, tasks, today)
      since = (today - 14).to_s
      agg = { name: name, user_id: user_id, open_pts: 0.0, recent: 0,
              total: tasks.size, dom: Hash.new(0), type: Hash.new(0) }
      tasks.each do |t|
        owners = [t.owners.size, 1].max
        agg[:open_pts] += t.points.to_f / owners unless CLOSED.include?(t.status)
        agg[:recent]   += 1 if t.created_at.to_s[0, 10] >= since
        t.domains.each { |d| agg[:dom][d] += 1 }
        agg[:type][t.type] += 1 if t.type
      end
      agg[:open_pts] = agg[:open_pts].round(1)
      agg
    end

    # Score candidates against `task`, using the CURRENT-SPRINT task list for
    # load/rotation/fit (so "load" means this sprint's load, not all-time —
    # consistent with nox being sprint-first; also instant since the board is
    # already in memory).
    #
    # `tasks` is the current sprint's [Nox::Task]; `task` is the Nox::Task being
    # assigned; `users` is [{id:, name:}] from Client#fetch_users (for ids).
    def evaluate(tasks:, task:, users:, today: Date.today, temperature: 0.3)
      id_for = WEIGHTED_OWNERS.each_with_object({}) do |name, h|
        h[name] = (users.find { |u| u[:name] == name } || {})[:id]
      end

      # Only score owners we can resolve to a Notion id (needed to write back).
      order = WEIGHTED_OWNERS.select { |n| id_for[n] }
      aggregates = order.map do |name|
        owned = tasks.select { |t| t.owner_names.include?(name) }
        aggregate(name, id_for[name], owned, today)
      end

      task_attrs = { priority: task.priority, domains: task.domains, type: task.type }
      result = score(aggregates: aggregates, task: task_attrs, temperature: temperature)
      result.merge(order: order, missing: WEIGHTED_OWNERS - order)
    end
  end
end
