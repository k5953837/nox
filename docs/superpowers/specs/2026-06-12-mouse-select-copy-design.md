# 滑鼠矩形選取複製（Mouse Rectangular Select-to-Copy）

**日期**：2026-06-12
**狀態**：已核准

## 目標

在 nox TUI 中，以滑鼠拖曳反白畫面上任意矩形區域，放開滑鼠後該區域文字自動複製到 macOS 系統剪貼簿。

## 背景

- ratatui_ruby 在 `init_terminal` 無條件送出 `EnableMouseCapture`（gem `ext/ratatui_ruby/src/terminal/init.rs:67`），terminal 原生反白複製因此失效。
- nox 已有滑鼠 click-to-select / double-click / scroll 處理（`lib/nox/app.rb` `handle_mouse_click`、`handle_mouse_scroll`），event 管線已打通。
- gem 提供 `Event::Mouse`（kind: down/drag/up + 座標）、`tui.get_cell_at(x, y)`（讀回畫面任一 cell）與 `draw_cell`（單格繪製），自製選取所需素材齊備。

## 已確認的設計決策

1. **App 內自製選取**（非關閉 mouse capture）：保留滑鼠點擊互動，體驗完整。
2. **矩形選取**（非流動式）：nox 是多 pane 版面，矩形不會跨欄掃進無關文字。
3. **drag 才啟動選取**：mouse down 同時是既有 click-to-select 的觸發點，down 只記 anchor 並照常走原邏輯；發生 drag 才進入選取狀態，兩功能互不干擾。
4. **複製管道用 pbcopy**：macOS 個人工具，不引入 OSC 52（YAGNI）。

## 架構

### 新增 `lib/nox/selection.rb` — `Nox::Selection`（純資料 model，無 I/O）

- 屬性：`anchor`（down 座標）、`cursor`（目前拖曳座標）
- `rect` → 正規化矩形 `[x_min, y_min, x_max, y_max]`（支援反向拖曳）
- `active?` / `start(x, y)` / `update(x, y)` / `clear`
- `single_cell?` → 判斷是否未實際拖出範圍（防誤觸）

### `lib/nox/app.rb` — 事件流

選取事件在 `handle_event` 的 mode dispatch **之前**全域攔截（所有 mode 都能選取）：

| 事件 | 行為 |
|------|------|
| `Mouse(down, left)` | 記 pending anchor，**照常**傳給 mode handler（click-to-select 不變） |
| `Mouse(drag, left)` | 啟動／更新選取（clamp 到畫面邊界），觸發重繪 |
| `Mouse(up, left)` | 選取作用中且非 single cell → 逐格 `get_cell_at` 取文字 → pbcopy → 清除選取、顯示 `✓ copied N chars`；否則僅清除 |
| 任意鍵盤事件 | 清除 copy notice |

### 反白渲染

每次 `tui.draw { render(frame) }` 完成後，若選取作用中：對矩形內每格 `get_cell_at` 讀回字元，以反轉樣式（reversed）`draw_cell` 疊回。Round 1 先以 headless spike 驗證 draw 後 overlay 的時序可行性。

### 文字擷取規則

- 逐行讀取矩形內 cell，每行右側 trim 空白，行間以 `\n` 連接。
- 拖曳超出 buffer 範圍時 clamp。
- 單擊不拖（1×1 矩形）視為取消，不覆寫剪貼簿。

### 複製管道

`IO.popen("pbcopy", "w")`。以可注入的 clipboard callable（預設 pbcopy lambda）注入 App，測試時替換為記錄用 lambda。

## 錯誤處理

- pbcopy 不存在或失敗：顯示 `✗ copy failed`，不 crash。
- 選取中視窗 resize：清除選取（座標已失效）。

## 測試策略

gem 自帶 `test_helper`：`init_test_terminal` + `inject_mouse`（支援 down/drag/up）+ snapshot assertion。

- Selection model 單元測試：正規化、反向拖曳、clamp、single_cell。
- 整合測試：注入 down→drag→up，斷言 clipboard lambda 收到的文字與反白渲染 snapshot。
- 既有測試全數通過（迴歸保護）。

## 成功條件

- C1: 滑鼠拖曳時畫面即時顯示矩形反白
- C2: 放開滑鼠後，矩形內文字（trim 行尾空白）進入系統剪貼簿
- C3: 反向拖曳、出界拖曳、單擊不誤觸，行為正確
- C4: 既有鍵盤操作與測試全數不受影響
