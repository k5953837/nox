# 派工轉盤 · Task Roulette (assigner)

把一張待指派的 Notion 任務，在 4 位 owner 之間做**有依據又好玩**的分配：
看真實負載 / 輪替 / 契合 → 轉一個**扇形面積＝真實機率**的轉盤 → 揭曉 →（Stage 1 僅 dry-run）。

候選人：Adora Xu · Lin CJ · Galen Lin · Hsiao Jimmy

## 跑起來

零依賴（純 Ruby stdlib，**不需 bundler / gem**），沿用 nox 的 `.env`（`NOTION_TOKEN` / `NOTION_DATABASE_ID`）。

```bash
ruby assigner/server.rb        # http://127.0.0.1:4567
# 自訂埠號： ASSIGNER_PORT=8080 ruby assigner/server.rb
```

首次開啟會掃描整個 Notion DB（約 10–20 秒），之後快取於記憶體；按右上「↻ 重新載入」可重掃。

## 測試

```bash
ruby assigner/test/scoring_test.rb   # 評分純函數單元測試（不需網路）
```

## 架構

| 檔案 | 角色 |
|---|---|
| `lib/env.rb` | 讀 `.env`（無 dotenv 依賴） |
| `lib/notion_gateway.rb` | Notion REST 唯讀 I/O（`scan_all`）＋ `patch_owner`（Stage 3 才用） |
| `lib/board.rb` | 原始 pages → 聚合 / 待指派清單 / id 對照（純解析） |
| `lib/scoring.rb` | **純函數評分引擎**：正規化 / 權重 / softmax / 理由 |
| `server.rb` | webrick：serve `public/` ＋ `/api/tasks`、`/api/score`、`/api/assign` |
| `public/` | 前端（Stage 2 用 frontend-design 打磨） |

## 評分摘要

- **可用度**：owner 未完成任務 `預估點數`（多 owner 平分）反向正規化。
- **輪替**：近 14 天被指派新任務數反向（`Created time` 近似）。
- **契合**：新任務 `Fault Domain`/`類型` 對歷史的重疊（低信心，無標籤時中性）。
- **優先級**：決定三者權重（P0/P1 重可用+契合；Low 重輪替）。
- `softmax(score ÷ T)`：T＝「命運感」，小＝理性、大＝好玩。

## 安全（Stage 1）

寫回**永遠 dry-run**：`POST /api/assign` 只回「會把 owner 設成誰」，**不送任何 PATCH**。真實寫回是 Stage 3，會加手動開關＋二次確認。

詳見 `docs/superpowers/specs/2026-06-22-notion-task-roulette-design.md`。
