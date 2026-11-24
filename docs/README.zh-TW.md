<div align="center">
  <img src="images/readme/app-icon.png" width="160" height="160" alt="Cellar 應用程式圖示">
  <h1>Cellar</h1>
  <p>在一個原生 Mac 應用程式裡，管理你的開發工具。</p>
  <p>
    <a href="../README.md">English</a> ·
    <a href="README.zh-CN.md">简体中文</a> ·
    <strong>繁體中文</strong> ·
    <a href="README.ja.md">日本語</a> ·
    <a href="README.ko.md">한국어</a> ·
    <a href="README.de.md">Deutsch</a> ·
    <a href="README.fr.md">Français</a> ·
    <a href="README.es.md">Español</a>
  </p>
</div>

Cellar 將 Homebrew 軟體、npm 全域套件、Node.js 版本和終端機設定集中到一個 macOS 應用程式中。查看已安裝的軟體，尋找新工具，完成更新，並在解除安裝前了解將要移除的內容。

> [!NOTE]
> Cellar 1.0 尚未公開發布，暫時沒有可下載的安裝檔或 Homebrew Cask。目前可以從原始碼建置；真實環境與介面驗收仍待完成。

## 你可以做什麼

| 工作 | 在 Cellar 中 |
|---|---|
| 查看環境狀態 | 在首頁查看 Homebrew、Node.js、npm、nvm 和終端機環境狀態。 |
| 管理已安裝軟體 | 在軟體庫瀏覽、搜尋和篩選 Homebrew Formula、Cask 與 npm 全域套件；單項更新、依篩選範圍批次更新，以及單項解除安裝。 |
| 尋找新工具 | 在探索頁面搜尋 Homebrew 和 npm，單項安裝或批次安裝同一類型的套件。 |
| 設定開發環境 | 透過 nvm 管理全域 Node.js 版本，管理 Homebrew Tap、npm 套件來源，以及 Oh My Zsh 佈景主題和外掛。 |
| 檢查與清理 | 執行 Homebrew 診斷和 npm 快取驗證，查看並確認支援的快取、未使用 Node 版本及舊 Manager 日誌清理工作。 |

工作進度和最近結果會在切換頁面後繼續顯示，批次工作部分成功時也能查看逐項結果。

介面支援**英文、簡體中文、繁體中文、日文、韓文、德文、法文和西班牙文**，預設選項為**跟隨系統**。也可以在「設定 > 一般」中選擇語言；變更後會重新啟動 Cellar。

## 系統需求與發布狀態

- **macOS 26 或更新版本**，執行於 **Apple Silicon Mac**（`arm64`）。
- 從原始碼建置需要 **Xcode 26 或更新版本**。
- Homebrew、Node.js、npm 和 nvm 是 Cellar 管理的工具，不隨應用程式附帶。

缺少 Command Line Tools 或 Homebrew 時，Cellar 可以開啟系統安裝流程；Homebrew 官方安裝套件會在開啟前完成驗證。nvm 提供安裝指引。

應用程式更新已透過 Sparkle 設定至共用的 [Homebrew Tap](https://github.com/SlippinDylan/homebrew-tap)。首次對應版本發布時，發布流程會建立簽章更新來源和 Cask。Debug 和一般本機建置停用應用程式更新。

## 從原始碼建置

```bash
git clone https://github.com/SlippinDylan/Cellar.git
cd Cellar
open Cellar.xcodeproj
```

在 Xcode 中選擇 **Cellar** scheme、**My Mac** 和 **Debug** 設定，按 **⌘R** 執行。Debug 使用本機臨時簽章（Sign to Run Locally），無需登入 Apple 開發者帳號或安裝簽章憑證。

也可以透過命令列建置：

```bash
xcodebuild build \
  -project Cellar.xcodeproj \
  -scheme Cellar \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData-Debug
```

應用程式產物位於 `build/DerivedData-Debug/Build/Products/Debug/Cellar.app`。測試、簽章和 Release 建置請參閱[開發指南](development.md)。

## 修改環境前需要了解

- npm 全域套件屬於特定的 Node.js 安裝。搜尋與操作綁定所選 Node 環境；Cellar 不管理專案內的 npm 相依套件。
- npm 套件搜尋與變更需要支援的 nvm 安裝；其他已偵測的 Node 安裝仍可讀取。Registry 使用者設定和快取維護依各自能力規則處理。套件來源網址支援無憑證 HTTPS，以及 `localhost`、`127.0.0.1`、`[::1]` 的本機 HTTP；不支援其他 HTTP 位址。
- 切換 Cellar 目前使用的 Node 版本僅影響本次 Cellar 工作階段，不會切換已開啟的終端機。Cellar 僅管理全域 Node/npm 環境，不管理單一專案的 `.nvmrc`。
- 軟體庫與探索頁面卡片中的單項套件安裝和更新直接開始；終端機元件安裝、批次操作、解除安裝、清理和設定變更會先確認範圍。執行中的工作無法手動停止，工作進行時 Cellar 會阻止結束應用程式。
- Homebrew Cask 解除安裝還可移除事先確認、能夠驗證歸屬的關聯資料，共用或無法核實的資料會保留。Formula 和 npm 解除安裝不包含這類關聯資料清理。Cellar 不執行 Homebrew cleanup，也不自動刪除孤立相依套件。
- 部分殘留檔案清理需要 macOS 管理員授權或完整磁碟存取權限。密碼由系統處理，Cellar 不收集密碼，也不安裝常駐特權服務；授權不保證所有檔案均可刪除。
- 操作可能部分成功。Cellar 會回報已完成項目和失敗項目，不承諾回復原狀；不修改 `.zprofile`，也不變更登入 Shell。

## 資料與網路

Cellar 沒有帳號、遙測或自有伺服器。工具查詢、搜尋、安裝、外掛和應用程式更新存取官方服務或你設定的來源。Homebrew 和 npm 查詢也可能寫入各自的快取。

官方 Homebrew Cask 圖示由 [CaskFlow](https://github.com/alielsokary/CaskFlow) 提供，透過 `cdn.jsdelivr.net` 下載。CDN 會收到所請求的 Cask 識別碼和一般連線資訊。CaskFlow 的 MIT 授權隨應用程式提供，軟體 Logo 的權益歸各自擁有者。

| 本機資料 | 位置 |
|---|---|
| 隨應用程式提供的 Manager 執行副本 | `~/Library/Application Support/Cellar/Managers/<version>/` |
| 日誌 | `~/Library/Logs/Cellar/` |
| 下載的軟體圖示 | `~/Library/Caches/com.dylanwang.Cellar/CatalogIcons/` |

日誌等級和保留期限可在「設定 > 一般」中調整。檔案日誌不儲存原始命令或 stdout/stderr；工作結果僅在目前工作階段保留。

## 專案文件

詳細專案文件目前使用中文：[文件索引](README.md)、[產品需求](requirements/product-requirements.md)、[整體架構](architecture/macos-app-architecture.md)、[開發指南](development.md)和[人工驗收清單](manual-smoke-checklist.md)。
