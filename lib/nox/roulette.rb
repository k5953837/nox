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

    # Title keyword -> Fault Domain map, hand-curated from the real tagged-task
    # corpus (frequency analysis, with customer names / generic words removed).
    # Used to *infer* a domain when a task has no Fault Domain set, so fit isn't
    # dead on freshly-created (untagged) tasks. Tweak freely — it's just data.
    DOMAIN_KEYWORDS = {
      "外部渠道與系統整合" => %w[line zendesk omnichat whatsapp shopline meta 渠道 串接 整合 綁定],
      "AI 腳本與推理邏輯"  => %w[腳本 script prompt 推理 邏輯 情境 推薦 flow agent],
      "AI 知識庫與檢索"    => %w[檢索 知識 retrieval rag 命中 embedding],
      "背景任務與同步異常" => %w[同步 sync race 排程 重複 webhook queue cron],
      "系統效能與超時"     => %w[逾時 timeout 超時 緩慢 效能 latency slow],
      "介面操作異常"       => %w[介面 文字 翻譯 按鈕 button ui 畫面 排版],
      "權限與身份驗證"     => %w[授權 token oauth 登入 login 權限 驗證 失效 unauthorized 未授權],
      "系統設定與快取"     => %w[設定 config 快取 cache],
      "輸入格式與資料解析" => %w[格式 解析 parse payload 分詞],
      "資料結構與版本遷移" => %w[schema migration 遷移 版本 結構 欄位],
    }.freeze

    # ── pure scoring ──────────────────────────────────────────────────────────

    # Infer Fault Domain(s) from a task title via keyword match. Returns the
    # top-scoring domain(s) (ties kept), or [] if no keyword hits. Pure.
    def infer_domains(title)
      return [] if title.nil? || title.empty?
      t = title.downcase
      scored = DOMAIN_KEYWORDS.map { |domain, kws| [domain, kws.count { |kw| keyword_hit?(t, kw) }] }
      best = scored.map { |_, n| n }.max
      return [] if best.nil? || best.zero?
      scored.select { |_, n| n == best }.map(&:first)
    end

    # ASCII keywords need word-ish boundaries (so "line" ∌ "online"); CJK
    # keywords match as plain substrings (no segmenter needed).
    def keyword_hit?(downcased_title, kw)
      if kw.match?(/\A[a-z0-9]+\z/)
        downcased_title.match?(/(?<![a-z])#{Regexp.escape(kw)}(?![a-z])/)
      else
        downcased_title.include?(kw)
      end
    end

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

    # Raw fit per candidate: overlap of the task's Fault Domain with each
    # candidate's history. Ticket `類型` was intentionally dropped — it rewarded
    # sheer volume / ticket-kind, not real domain expertise. So Ft is honestly
    # neutral (0.5 for all) whenever the task has no Fault Domain.
    def fit_raw(domains, aggregates)
      aggregates.map do |a|
        (domains || []).sum { |d| (a[:dom] && a[:dom][d]) || 0 }.to_f
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
      raw    = fit_raw(task[:domains], aggregates)
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
        unless matched.empty?
          suffix = task[:inferred] ? "·推測" : ""
          bits << "領域契合(#{matched.join('、')}#{suffix})"
        end
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

    # Build one candidate aggregate. Two time-scales on purpose:
    #   load + rotation  <- current sprint (sprint_tasks)  = "how busy right now"
    #   fit (Fault Domain) <- full history (history_tasks) = accumulated expertise
    # Multi-owner pts are split across co-owners so load isn't double-counted.
    def aggregate(name, user_id, sprint_tasks, history_tasks, today)
      since = (today - 14).to_s
      agg = { name: name, user_id: user_id, open_pts: 0.0, recent: 0,
              total: sprint_tasks.size, dom: Hash.new(0) }
      sprint_tasks.each do |t|
        owners = [t.owners.size, 1].max
        agg[:open_pts] += t.points.to_f / owners unless CLOSED.include?(t.status)
        agg[:recent]   += 1 if t.created_at.to_s[0, 10] >= since
      end
      agg[:open_pts] = agg[:open_pts].round(1)
      history_tasks.each { |t| t.domains.each { |d| agg[:dom][d] += 1 } }
      agg
    end

    # Score candidates against `task`. Hybrid time-scales (by design):
    #   sprint_tasks    : current sprint [Nox::Task]            -> load + rotation
    #   history_by_name : { name => [Nox::Task] full history }  -> fit (expertise)
    # `task` is the Nox::Task being assigned; `users` is [{id:, name:}] (for ids).
    def evaluate(sprint_tasks:, history_by_name:, task:, users:, today: Date.today, temperature: 0.3)
      id_for = WEIGHTED_OWNERS.each_with_object({}) do |name, h|
        h[name] = (users.find { |u| u[:name] == name } || {})[:id]
      end

      # Only score owners we can resolve to a Notion id (needed to write back).
      order = WEIGHTED_OWNERS.select { |n| id_for[n] }
      aggregates = order.map do |name|
        sprint_owned = sprint_tasks.select { |t| t.owner_names.include?(name) }
        aggregate(name, id_for[name], sprint_owned, history_by_name[name] || [], today)
      end

      # Use the task's real Fault Domain if set; otherwise infer from its title
      # (low-confidence, flagged). No domain at all -> fit stays neutral.
      real = task.domains || []
      if real.empty?
        domains  = infer_domains(task.title)
        inferred = !domains.empty?
      else
        domains  = real
        inferred = false
      end

      task_attrs = { priority: task.priority, domains: domains, inferred: inferred }
      result = score(aggregates: aggregates, task: task_attrs, temperature: temperature)
      result.merge(order: order, missing: WEIGHTED_OWNERS - order,
                   effective_domains: domains, domain_inferred: inferred)
    end
  end
end
