# 派工轉盤（Notion Task Roulette）— 設計文件

**日期**：2026-06-22
**狀態**：已實作，但**設計已大幅演進**（本文件保留為最初 brainstorm 紀錄）
**作者**：brainstorming 協作產出

> ⚠️ **此文件是最早的 web 版設計，實作時已轉向，請勿照本文件理解現況。**
> 最終實作為 **nox 的 TUI 功能**（非獨立 web 工具）：按 `x` → 派工建議 popup。
> 主要演進：①web → nox TUI（ratatui_ruby）；②加權隨機抽選 → **argmax 取最高**（非隨機）；
> ③負載/輪替＝**當期 sprint**、契合＝**全歷史**；④契合只用 `Fault Domain`（去掉 `類型`）；
> ⑤無領域時由**標題關鍵字推測**領域。**現況請以 `README.md` 的「Auto-assign (派工建議)」節與
> `lib/nox/roulette.rb` 為準。**

---

## 1. 目標

幫使用者決定「一張新的 Notion 任務該排給誰」，在三位候選 owner 之間做出**有依據又好玩**的指派決定：

- 候選人：**Adora Xu / Galen Lin / Hsiao Jimmy / Lin CJ**（4 人；原始名單第四項 Galen Lin 為重複，Lin CJ 為後續追加）。
- 形式：本機 web 工具。挑一張待指派任務 → 看四人的真實負載/輪替/契合 → 轉一個**忠於權重**的轉盤 → 揭曉理由 →（確認後）寫回 Notion `owner`。
- 核心張力：同時做到「有趣」（轉盤儀式感、命運感滑桿）與「誠實」（扇形面積＝真實中選機率，不假裝隨機卻內定）。

非目標見 §11。

---

## 2. 背景與限制（已用真實資料驗證）

對 `New Sprint Board`（`NOTION_DATABASE_ID`）做過 schema dump + 40 筆樣本 + 三位候選人歷史聚合，得到以下**事實**（非假設）：

| 發現 | 影響 |
|---|---|
| DB 近 **4900** 筆任務（live、持續增長） | server **必須用 filter 查詢**（按 owner / status），不能每次全撈 |
| 人名 number 欄位（Adora/Galen/Jimmy…）**幾乎全空** | 棄用；不是工作量矩陣 |
| `owner`(people) 大量使用；`Assign`(people) 幾乎無人用 | 指派寫回 **`owner`**（與 nox 一致） |
| `預估點數`(pts) 填得很滿 | 工作量用 pts 加總 |
| fit 標籤覆蓋率：`Projects` 0%、`Labels` 0%、`類型` 4–16%、`Fault Domain` 3–39% | `Projects`/`Labels` **死欄位丟棄**；fit 只能當**低信心輔助因素**，並用標題關鍵字補強 |
| `Priority` select 含 **P0🔥 - 4hr / P1🔴 - 8hr / P2🟡 - 5wd / P3 - Request / High / Medium / Low**（**有 P0**） | 優先級調節權重；比對用 `P[0-3]` 前綴 + High/Med/Low |
| `Status` 有 `Pending Assignment` / `Not started` 等 13 種 | 待指派清單用 status filter |
| 這是**正式生產看板**（真實客戶、事故、人員指派） | 寫回是真正風險 → 預設 dry-run + 明確 confirm + 開發期只寫測試任務 |
| 系統 Ruby 2.6.10，stdlib 有 `webrick`/`net/http`/`json`/`minitest`；專案 bundler 版本衝突（rake 缺失） | backend **零新依賴、純 stdlib**，完全不碰 bundler/gem |

四人實測負載（建模基準，非寫死值）：

| 候選人 | 未完成任務 | 未完成 pts | 近 14 天新任務 | fit 標籤覆蓋（傾向） |
|---|---|---|---|---|
| Adora Xu | 7 | 87 | 10 | Fault Domain 39%（介面/AI 知識庫） |
| Galen Lin | 14 | 151 | 22 | 稀疏 3–4%（外部整合/背景同步） |
| Hsiao Jimmy | 35 | 341 | 47 | 稀疏 4–16%（廣，偏背景任務） |
| Lin CJ | 12 | 125 | 8 | Fault Domain 13%（**AI 腳本/推理**、AI 知識庫） |

→ 誠實加權下轉盤不會一面倒：**Adora**（最閒）與 **Lin CJ**（最近被指派最少＝最新鮮、且 AI 腳本/推理領域最集中）依任務性質互有高低；Galen 居中；**Jimmy（爆量 341pts）權重最低**。任務若沾「AI 腳本/推理」，fit 因素首次出現真實差異訊號（偏 Lin CJ）。這正是工具的價值。

---

## 3. 架構（零新依賴）

放在 nox repo 的 **`assigner/`** 子資料夾，**完全不動 TUI 程式碼**（尊重 nox golden-sample / friction-driven 原則）。

```
assigner/
  server.rb            # webrick 路由；serve public/ + JSON API
  lib/
    notion_gateway.rb  # 純 Notion REST 封裝（net/http）：query / users / patch owner
    profiles.rb        # 從原始任務聚合候選人 aggregate（負載/輪替/歷史 profile）
    scoring.rb         # 純函數：aggregate + task + weights + temperature → 分數/機率/理由
    env.rb             # 讀 .env（沿用 nox 的 NOTION_TOKEN / NOTION_DATABASE_ID）
  public/
    index.html         # 前端（/frontend-design 主角）
    style.css
    app.js
  test/
    scoring_test.rb    # minitest（stdlib），純函數單元測試
  README.md            # 如何啟動、dry-run 說明
```

啟動：`ruby assigner/server.rb`（讀 `.env`，預設 `http://localhost:4567`）。

### API

| Method | Path | 說明 |
|---|---|---|
| `GET` | `/api/tasks?q=` | 待指派任務清單。filter `Status = Pending Assignment` 或 `Not started`；`q` 為標題子字串搜尋。回 id/title/priority/status/類型/Fault Domain。 |
| `GET` | `/api/candidates?task_id=` | 對選定任務算四人 aggregate（負載/輪替/fit）與原始分量，供前端即時調權重。 |
| `POST` | `/api/assign` | body `{task_id, user_id, dry_run}`。`dry_run=true`（預設）只回「會寫什麼」不送；`false` 才 PATCH `owner`。 |

權重/溫度的最終 softmax 與扇形計算放**前端**（滑桿即時反應，不需 round-trip）；server 只回正規化前的原始分量與必要 metadata。

---

## 4. 資料模型與 Notion 整合

`notion_gateway.rb`（純 I/O，無商業邏輯）：

- `query(filter:, sorts:, page_size:)` — 分頁包裝 `POST /v1/databases/{id}/query`。
- `users()` — `GET /v1/users`，取候選人 `user_id`（寫回 owner 需要）。
- `patch_owner(page_id:, user_ids:)` — `PATCH /v1/pages/{id}`，`properties.owner.people`。

`profiles.rb`：給定四人名字 →

- **負載 aggregate**：filter `owner contains <id>` 且 `Status ∉ {Done, Archived}`；`open_pts_c = Σ (task.預估點數 / 該任務 owner 人數)`（**多 owner 平分**，避免重複計）。
- **輪替 aggregate**：同上 filter + `Created time ≥ today−14d`，計數 `recent_c`。
- **歷史 profile（fit）**：filter `owner contains <id>`、近 ~90 天或最近 N=200 筆，建 `Fault Domain` / `類型` 頻率表 + 標題 token bag（中文用 char-bigram 簡化）。

---

## 5. 評分模型（透明、可解釋、加總為機率）

對候選人 `c` 與新任務 `t`：

**因素分數（各自 min-max 正規化到 [0,1]，跨四人）**

1. **可用度** `A_c = 1 − minmax(open_pts_c)` — 最閒 → 1。
2. **輪替新鮮度** `Fr_c = 1 − minmax(recent_c)` — 最近被指派越少 → 越高。
   - 揭曉時誠實標示為「最近被指派的新任務較少」；Notion 無真正指派時間，以 `Created time` 近似。
3. **契合度** `Ft_c`（低信心輔助、小權重）：
   - `tag_sim` = `t` 的 {Fault Domain, 類型} 與 `c` 頻率表的加權重疊；`t` 無標籤或四人皆無訊號 → 中性。
   - `kw_sim` = `t.title` token 與 `c` 標題 token bag 的 Jaccard/cosine（標題永遠存在，是主訊號）。
   - `Ft_raw = α·tag_sim + (1−α)·kw_sim`（α 偏小，因標籤稀疏），再 min-max；四人接近時自然趨中性。
   - 附 **confidence** 指標（由標籤覆蓋 + kw 重疊量決定），低信心在 UI 標示。

**優先級調節**（`t.Priority` → 預設權重起點，使用者滑桿可覆寫）

| 優先級 | (w_可用, w_輪替, w_契合) | 理由 |
|---|---|---|
| P0🔥 / P1🔴 | (0.5, 0.1, 0.4) | 緊急 → 給最閒最懂的人，不為公平硬分 |
| P2 / P3 / High / Medium / 無 | (0.4, 0.3, 0.3) | 平衡 |
| Low | (0.3, 0.5, 0.2) | 不急 → 輪替/公平優先 |

**合成與機率**

```
score_c = w_可用·A_c + w_輪替·Fr_c + w_契合·Ft_c
p_c     = softmax(score_c / T)            # T = 「命運感」滑桿
arc_c   = p_c · 360°                        # 扇形面積 = 中選機率（誠實）
```

- `T → 0`：趨近總選最高分（理性）。`T` 大：趨近均等（純好玩）。預設中等。
- 轉盤命中＝依 `p` 的加權隨機抽樣（前端 seeded，可重播）。

---

## 6. 觸發模型與選任務 UX（Live 清單 + 搜尋）

**觸發模型（已定案）**：**手動 on-demand（pull）**。沒有背景常駐程式、沒有輪詢、沒有自動寫回。觸發＝使用者「開工具 → 挑任務 → 轉 →（手動確認）寫回」。Notion 無可靠即時 webhook，未來若要「新任務自動通知」只能靠輪詢，屬另一階段、非本版範圍（§11）。

- 開啟即 `GET /api/tasks` 拉待指派清單，下拉/卡片可點選。
- 搜尋框即時過濾（標題子字串）。
- 選定後顯示該任務的 Priority / 類型 / Fault Domain chips，並 `GET /api/candidates` 重算扇形。
- （未來可選）貼 Notion URL/ID 鎖定單一任務 — 本版不做（§11）。

---

## 7. 有趣的揭曉（frontend-design 主角）

由 `/frontend-design:frontend-design` 打造：

- **轉盤**：四人扇形，面積＝`p_c`（誠實）；旋轉減速命中加權隨機結果，有張力。
- **候選卡**：每人顯示可用度條 / 契合度（含 confidence）/ 輪替，與當前 `p_c`。
- **滑桿**：三個因素權重 + 「命運感」溫度滑桿；拖動即時改變扇形面積。
- **揭曉**：命中後高亮贏家 + 一句「為什麼是他」（例：「最閒（7/87pts）＋最近被指派最少（10）＋懂外部渠道整合」）。
- **寫回按鈕**：見 §8。

視覺風格沿用使用者偏好（文字標籤優先於純 glyph、色弱友善、極簡）。

---

## 8. 安全：dry-run 寫回

正式生產看板，寫回為主要風險：

1. **預設 dry-run**：揭曉後按鈕顯示「（dry-run）會把 owner 設成 X」，`POST /api/assign {dry_run:true}` 只回 payload 不送。
2. 要**手動切換** "真的寫回 Notion" 開關，且按下後**再 confirm 一次**才 `dry_run:false` PATCH。
3. **開發期**只對一張指定測試任務驗證真實寫入。
4. 寫回成功後顯示 Notion 連結供人工複查。

---

## 9. 元件邊界（隔離與清晰）

| 元件 | 做什麼 | 依賴 | 可獨立測試 |
|---|---|---|---|
| `notion_gateway` | Notion REST I/O | net/http、token | 可（錄製/手動） |
| `profiles` | 原始任務 → 候選人 aggregate | gateway | 可（餵假任務） |
| `scoring` | aggregate+task+權重 → 分數/機率/理由（**純函數、零 I/O**） | 無 | **可，單元測試核心** |
| `server` | webrick 路由接線 + serve static | 上三者 | 手動 smoke |
| `public/*` | 轉盤/卡片/滑桿/揭曉 | API | 手動 |

`scoring` 為純函數是刻意設計：min-max、softmax、優先級調節、理由生成全部可單元測試，不需碰 Notion。

---

## 10. 錯誤處理與測試

- **錯誤**：缺 token → 啟動即報錯退出；Notion API 非 2xx → server 回 JSON error，前端顯示友善訊息；任務無候選人歷史 → fit 中性 + 標示低信心；查詢用 filter 故規模小，rate-limit 風險低。
- **測試**：`scoring_test.rb` 用 stdlib minitest 覆蓋正規化/softmax/優先級權重/多 owner pts 平分/理由生成；server 手動 smoke；寫回安全由 dry-run 預設保證。

---

## 11. 非目標（YAGNI）

- 編輯 owner 以外的 Notion 屬性（狀態、點數…）。
- 批次/多任務指派。
- 多人協作、登入、權限。
- 持久化歷史/指派紀錄。
- 使用 `Assign` 欄位。
- 貼 URL 選任務（本版以清單為主）。
- 背景監看 / 輪詢 / 自動通知 / 自動指派（觸發模型定為手動 on-demand，見 §6）。

---

## 12. 分階段實作（先 thin vertical slice，避免做完才發現死因素）

- **Stage 1 — 垂直切片**：`env` + `notion_gateway` + `profiles` + `scoring` + `GET /api/tasks` + `GET /api/candidates`；極簡 HTML 顯示四張卡的**真實**負載/輪替/fit 數字 + 一個基本轉盤；寫回**僅 dry-run（stub）**。目的：及早驗證 fit 是否真有差異訊號。
- **Stage 2 — frontend-design 打磨**：真正的轉盤、滑桿、揭曉動畫、理由。
- **Stage 3 — 真實寫回**：手動開關 + 二次 confirm + 測試任務驗證 `PATCH owner`。

實作交付路徑：本 spec 經 review 後 → 進 `/frontend-design:frontend-design` 做 §7 前端主角，backend 依 §3/§9 並行。
