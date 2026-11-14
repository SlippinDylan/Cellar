<div align="center">
  <img src="images/readme/app-icon.png" width="160" height="160" alt="Cellar アプリのアイコン">
  <h1>Cellar</h1>
  <p>Mac の開発ツールを、ひとつのネイティブアプリで管理。</p>
  <p>
    <a href="../README.md">English</a> ·
    <a href="README.zh-CN.md">简体中文</a> ·
    <a href="README.zh-TW.md">繁體中文</a> ·
    <strong>日本語</strong> ·
    <a href="README.ko.md">한국어</a> ·
    <a href="README.de.md">Deutsch</a> ·
    <a href="README.fr.md">Français</a> ·
    <a href="README.es.md">Español</a>
  </p>
</div>

Cellar は、Homebrew のソフトウェア、npm のグローバルパッケージ、Node.js のバージョン、ターミナルの設定をひとつにまとめた macOS アプリです。インストール済みのソフトウェアを確認し、新しいツールを探して更新できます。アンインストールする前には、削除される内容を確認できます。

> [!NOTE]
> Cellar 1.0 はまだ一般公開されていません。ダウンロードできるインストーラや Homebrew Cask はありません。ソースからビルドできますが、実環境と UI の受け入れ確認はまだ完了していません。

## できること

| 作業 | Cellar での操作 |
|---|---|
| 環境の状態を確認 | ホームで Homebrew、Node.js、npm、nvm、ターミナル環境の状態を確認できます。 |
| インストール済みソフトウェアの管理 | ライブラリで Homebrew Formula、Cask、npm グローバルパッケージを閲覧・検索・絞り込みできます。個別更新、絞り込んだ対象の一括更新、個別アンインストールに対応しています。 |
| 新しいツールを探す | 探索ページで Homebrew と npm を検索し、個別に、または同じパッケージ種別をまとめてインストールできます。 |
| 開発環境の設定 | nvm による Node.js のバージョン管理、選択したプロジェクトの `.nvmrc`、Homebrew Tap、npm レジストリ、Oh My Zsh のテーマとプラグインを管理できます。 |
| 検査とクリーンアップ | Homebrew の診断や npm キャッシュの検証を行い、対応するキャッシュ、未使用の Node バージョン、古い Manager ログの削除対象を確認できます。 |

ページを移動しても、タスクの進捗と直近の結果を確認できます。一括処理が一部だけ成功した場合も、項目ごとの結果が表示されます。

インターフェイスは**英語、簡体字中国語、繁体字中国語、日本語、韓国語、ドイツ語、フランス語、スペイン語**に対応しています。既定の選択肢は「システムに従う」です。「設定 > 一般」で言語を指定することもできます。言語を変更すると Cellar が再起動します。

## システム要件と公開状況

- **Apple Silicon Mac**（`arm64`）上の **macOS 26 以降**。
- ソースからのビルドには **Xcode 26 以降**が必要です。
- Homebrew、Node.js、npm、nvm は Cellar が管理するツールであり、アプリには同梱されていません。

Command Line Tools または Homebrew がない場合は、Cellar からシステムのインストール手順を開始できます。Homebrew の公式インストーラパッケージは、開く前に検証されます。nvm については、インストール手順を案内します。

アプリの更新には Sparkle を使用し、共有の [Homebrew Tap](https://github.com/SlippinDylan/homebrew-tap) を更新元として設定しています。署名付きの更新フィードと Cask は、対応する最初のリリース時に作成されます。Debug ビルドと通常のローカルビルドでは、アプリの更新は無効です。

## ソースからビルド

```bash
git clone https://github.com/SlippinDylan/Cellar.git
cd Cellar
open Cellar.xcodeproj
```

Xcode で **Cellar** スキーム、**My Mac**、**Debug** 構成を選び、**⌘R** で実行します。Debug はローカルのアドホック署名（Sign to Run Locally）を使用するため、Apple 開発者アカウントへのサインインや署名証明書のインストールは不要です。

コマンドラインからもビルドできます。

```bash
xcodebuild build \
  -project Cellar.xcodeproj \
  -scheme Cellar \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData-Debug
```

ビルドされたアプリは `build/DerivedData-Debug/Build/Products/Debug/Cellar.app` にあります。テスト、署名、Release ビルドについては[開発ガイド](development.md)を参照してください。

## 環境を変更する前に

- npm グローバルパッケージは、それぞれ特定の Node.js インストールに属します。検索と操作には選択した Node 環境を使用します。プロジェクト内の npm 依存パッケージは管理しません。
- npm パッケージの検索と変更には対応する nvm インストールが必要です。その他の検出済み Node インストールは読み取りできます。Registry のユーザー設定とキャッシュ保守にはそれぞれの対応条件が適用されます。Registry URL は認証情報を含まない HTTPS と `localhost`、`127.0.0.1`、`[::1]` のローカル HTTP に対応し、他の HTTP アドレスには対応しません。
- Cellar が使用する Node バージョンの切り替えは、現在の Cellar セッションにのみ反映され、すでに開いているターミナルには反映されません。プロジェクトの `.nvmrc` の保存は必要なバージョンを宣言するだけで、Node の自動インストールやターミナルのバージョン切り替えは行いません。
- ライブラリと探索ページのカードから行う個別パッケージのインストールと更新は、すぐに開始します。ターミナルコンポーネントのインストール、一括操作、アンインストール、クリーンアップ、設定変更では、先に対象範囲を確認します。実行中のタスクを手動で停止することはできません。タスクが実行中の場合、Cellar は終了を許可しません。
- Homebrew Cask のアンインストールでは、事前に確認し、対象への帰属を検証できる関連データも削除できます。共有データや帰属を確認できないデータは残します。Formula と npm のアンインストールには、この関連データのクリーンアップは含まれません。Homebrew cleanup の実行や、不要になった依存パッケージの自動削除は行いません。
- 一部の残存ファイルの削除には、macOS の管理者認証またはフルディスクアクセスが必要です。パスワードは macOS が処理します。Cellar はパスワードを収集せず、特権サービスを常駐させません。権限を許可しても、すべてのファイルを削除できるとは限りません。
- 操作は一部だけ成功する場合があります。Cellar は完了した項目と失敗した項目を表示しますが、ロールバックは保証しません。`.zprofile` やログインシェルは変更しません。

## データとネットワーク

Cellar にはアカウント、テレメトリ、独自のバックエンドはありません。ツールの照会、検索、インストール、プラグイン、アプリの更新には、公式サービスまたはユーザーが設定した取得元に接続します。Homebrew や npm の照会時には、それぞれのキャッシュに書き込まれる場合もあります。

公式 Homebrew Cask のアイコンは [CaskFlow](https://github.com/alielsokary/CaskFlow) から `cdn.jsdelivr.net` 経由で取得します。CDN には、要求した Cask 識別子と通常の接続情報が送信されます。CaskFlow の MIT ライセンスはアプリに同梱されています。ソフトウェアのロゴに関する権利は、それぞれの権利者に帰属します。

| ローカルデータ | 保存場所 |
|---|---|
| 同梱 Manager の実行用コピー | `~/Library/Application Support/Cellar/Managers/<version>/` |
| ログ | `~/Library/Logs/Cellar/` |
| ダウンロードしたソフトウェアアイコン | `~/Library/Caches/com.dylanwang.Cellar/CatalogIcons/` |

ログの記録レベルと保存期間は「設定 > 一般」で変更できます。ファイルログに生のコマンドや stdout/stderr は保存しません。タスク結果は現在のセッション中だけ保持します。

## ドキュメント

詳細なプロジェクト文書は現在、中国語で提供しています。[ドキュメント一覧](README.md)、[製品要件](requirements/product-requirements.md)、[アーキテクチャ](architecture/macos-app-architecture.md)、[開発ガイド](development.md)、[手動受け入れ確認リスト](manual-smoke-checklist.md)を参照してください。
