# Awake

**MacBook の蓋を閉じても、Mac をスリープさせない。**

Awake は、長時間かかる作業を止めないための macOS ネイティブのメニューバー常駐アプリです。
SSH やリモートセッション、ダウンロード、ビルド、バックアップ、データ処理など、MacBook の蓋を閉じたまま
続けたい作業に使います。すべて Swift で実装し、macOS 標準のフレームワークだけを使っています。

利用者向けの手順は [`docs/tester-guide-ja.md`](docs/tester-guide-ja.md) を参照してください。

## 安全設計

Awake は「スリープを防ぐこと」よりも「確実に元に戻すこと」を優先します。Awake が変更した電源設定については、
特権ヘルパーが `/usr/bin/pmset -a disablesleep 0` の完了を確認するまで、メニューに OFF と表示しません。
Awake 以外が設定した `SleepDisabled 1` が最初から有効な場合は、黙って上書きせずに警告を表示します。

- IOKit のアイドルスリープ抑止アサーションはアプリ本体のプロセスが保持します。アプリが落ちると macOS が自動で解放します。
- root 権限の最小限の LaunchDaemon（ヘルパー）は、`pmset` の変更と復旧用のリースだけを担当します。
- ヘルパーは `disablesleep` を有効にする前に、root だけが読み書きできる永続マーカーを書き込みます。
- XPC 接続が切れるとすぐに元に戻します。独立した安全策として、45 秒間ハートビートが途絶えた場合も元に戻します。
- ヘルパーが強制終了されても `launchd` が再起動し、起動時にマーカーを検出して、処理を受け付ける前に復旧します。
- 復旧に失敗した場合はマーカーを残し、5 秒ごとに再試行します。
- XPC の接続相手は、バンドル ID と署名の Team ID が一致するものに限定しています。任意のコマンド・パス・引数を
  特権側に渡すことはできません。
- ヘルパーとの XPC 通信は 10 秒でタイムアウトします。登録済みなのにヘルパーに接続できない場合は、
  アプリから登録し直して 1 回だけ再試行します（下記「トラブルシューティング」参照）。

ヘルパーは `SMAppService` を使ってアプリバンドル内から登録します。ターミナルのような `sudo` のパスワード入力は
行いません。初回登録時に、macOS 標準の「バックグラウンド項目」の許可フローが表示されます。

## 機能

- メニューバー専用の SwiftUI アプリ（`MenuBarExtra`）。Dock には表示されません
- Awake の ON / OFF と、分かりやすい状態表示
- タイマー: オフ / 1・2・4・8 時間 / 任意時間
- バッテリー保護: オフ / 10% / 20% / 30%（AC 電源接続中は無効）
- 温度保護: `serious` または `critical` が 3 分間続くと自動で OFF
- バッテリー残量、電源、温度状態、タイマー残り時間のリアルタイム表示
- アプリ・ヘルパーとも Universal 2（`x86_64` + `arm64`）
- ログイン時の自動起動の ON / OFF（`SMAppService.mainApp`）
- アプリ内アンインストール
- Hardened Runtime 対応の Developer ID 配布と、公証済み DMG の作成スクリプト

## アーキテクチャ

```text
Awake.app（ログイン中のユーザー権限）
  SwiftUI のメニューバーと状態管理
  IOKit アイドルスリープ抑止アサーション
  IOKit バッテリー / AC 電源の状態取得
  ProcessInfo の温度状態
  タイマーと安全ポリシー
             |
             | 署名で認証した NSXPCConnection
             v
AwakeHelper（root 権限、SMAppService の LaunchDaemon）
  固定の enable / heartbeat / restore API のみ
  root 専用の永続リースマーカー
  /usr/bin/pmset -a disablesleep 1 または 0
  XPC 切断・ハートビート途絶時の自動復旧
```

## ソース構成

```text
Awake.xcodeproj/
macOS/
  AwakeApp/       SwiftUI アプリ、ライフサイクル、XPC クライアント
  AwakeCore/      アサーション、状態監視、安全ポリシー
  AwakeHelper/    root デーモン、pmset 操作、永続リース
  AwakeShared/    定数と最小限の XPC プロトコル
  AwakeTests/     安全ポリシーの決定的なテスト
docs/TESTING.md         特権操作・実機テストの手順
docs/tester-guide-ja.md 社内試用者向けガイド
scripts/                Universal ビルドと公証済み DMG の作成
```

## 動作・開発環境

- macOS 13 Ventura 以降
- Xcode 16 以降
- ヘルパー登録用のコード署名チーム
- 配布用には Apple Developer Program のメンバーシップ、Developer ID 証明書、公証用の認証情報

`MenuBarExtra` と現行の `SMAppService` LaunchDaemon API がどちらも macOS 13 からのため、デプロイターゲットは
macOS 13 です。それより古い macOS に対応するには、別の UI 実装と非推奨のヘルパーインストール方式が必要になります。

App Sandbox は意図的に無効にしています。Hardened Runtime を使い、汎用的な root 権限 API は公開していません。
配布形態は Mac App Store 外の Developer ID 配布です。

## 識別子と署名チーム

| 項目 | 値 |
| --- | --- |
| アプリのバンドル ID | `jp.co.seeds-std.Awake` |
| ヘルパーのバンドル ID / Mach サービス / LaunchDaemon ラベル | `jp.co.seeds-std.Awake.Helper` |
| リースマーカーのディレクトリ | `/var/db/jp.co.seeds-std.Awake` |
| Apple Developer Team ID | `VKKULG2DQ5` |

Team ID は秘密情報ではなく、署名済みのバイナリすべてに埋め込まれます。プロジェクトのビルド設定に設定されており、
ビルドスクリプトのデフォルト値にもなっています。アプリ ID、ヘルパー ID、Mach サービス、LaunchDaemon ラベル、
マーカーのパス、XPC の署名要件、プロジェクトのビルド設定は、常に一致させておく必要があります。

## 初回セットアップ（署名・公証の準備）

配布用 DMG を作るマシンで、最初に 1 回だけ行います。

### 1. Apple Developer Program と Xcode のアカウント

1. Team `VKKULG2DQ5` の Apple Developer Program に参加しているアカウントを用意します。
2. Xcode の **Settings > Accounts** でその Apple ID にサインインします。
   開発用の `Apple Development` 証明書は、Xcode でビルドすると自動で作成されます。

### 2. Developer ID Application 証明書の発行

配布用アプリの署名には `Developer ID Application` 証明書が必要です。
**この証明書を作成できるのは、チームの Account Holder（アカウント所有者）だけです。**

- **Xcode で作成する場合:** **Settings > Accounts** でチームを選び、**Manage Certificates…** で
  **＋ > Developer ID Application** を選びます。
- **Web で作成する場合:** 「キーチェーンアクセス」の **証明書アシスタント > 認証局に証明書を要求** で CSR を作成し、
  [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list) で
  **Developer ID Application** 証明書を発行します。ダウンロードした `.cer` をダブルクリックして、
  ログインキーチェーンに追加します。

別の Mac で作成した証明書を使う場合は、作成した Mac の「キーチェーンアクセス」から秘密鍵ごと `.p12` で書き出し、
DMG を作る Mac に読み込みます（`.cer` だけでは署名できません）。

次のコマンドで、証明書と秘密鍵がそろっているか確認できます。

```bash
security find-identity -v -p codesigning
```

`Developer ID Application: <名前> (VKKULG2DQ5)` が表示されれば準備完了です。

### 3. App 用パスワードの発行

公証（notarization）には、Apple ID の App 用パスワードを使います。

1. [account.apple.com](https://account.apple.com) にサインインします。
2. **サインインとセキュリティ > App 用パスワード** で新しいパスワードを作成します（名前は例として `AwakeNotary`）。

### 4. 公証用の認証情報をキーチェーンに保存

リポジトリに秘密情報を置かないよう、公証用の認証情報はキーチェーンに保存します。

```bash
xcrun notarytool store-credentials AwakeNotary \
  --apple-id 'YOUR_APPLE_ID' \
  --team-id 'VKKULG2DQ5' \
  --password 'APP_SPECIFIC_PASSWORD'
```

> **`AwakeNotary` について:** これは公証用の認証情報（Apple ID・Team ID・App 用パスワード）をキーチェーンに
> 保存するときに付ける**プロファイル名**です。DMG 作成時に `NOTARY_PROFILE` でこの名前を指定します。
> 署名に使う証明書（`Developer ID Application: …`）の名前とは別物です。

## 配布用 DMG の作成

初回セットアップが済んでいれば、リポジトリのルートで次のコマンドを実行するだけです。

```bash
NOTARY_PROFILE=AwakeNotary ./scripts/release-notarized-dmg.sh
```

`NOTARY_PROFILE` には、初回セットアップの手順 4 で保存した公証用プロファイル名（`AwakeNotary`）を指定します。

スクリプトは次の処理を行います（公証の待ち時間を含めて数分かかります）。

1. Universal 2 アプリを `Developer ID Application` 証明書で署名してアーカイブ
2. 埋め込まれた署名とアーキテクチャを検証
3. アプリを公証し、公証チケットを埋め込み（staple）
4. DMG を作成して署名
5. DMG を公証し、公証チケットを埋め込み、Gatekeeper で検証

出力先は `build/distribution/Awake.dmg` です。以前の DMG は上書きされます。

- ビルド番号（`CFBundleVersion`）には `main` のコミット数が自動で設定されます。未コミットの変更があるとスクリプトは中断します。
- バージョン表記（`MARKETING_VERSION`、例: `0.1.0`）は必要に応じて Xcode のプロジェクト設定で変更してください。
- アプリは起動時に、動作中の補助プログラムのバージョンが自分と異なれば登録し直して入れ替えます。
  そのため配布先は DMG から上書きインストールするだけで更新できます。

## 開発用ビルド

`Awake.xcodeproj` を開いてビルドします。`Awake` と `AwakeHelper` の両ターゲットで Team `VKKULG2DQ5` を使います。
特権ヘルパーを登録できる、署名済みの Universal 2 開発用ビルドは次のコマンドで作成します。

```bash
./scripts/build-development.sh
```

`build/Awake.app` が作成されます。Awake を ON にする前に `/Applications` にコピーしてください。
その Team ID の Apple 発行の署名証明書が、ログインキーチェーンに入っている必要があります。

コンパイル確認だけを目的とした、署名なしの Universal 2 ビルドは次のとおりです。

```bash
./scripts/build-universal.sh
```

`build/Awake-unsigned.app` が作成され、アプリとヘルパーの両方に `x86_64` と `arm64` が含まれているか検証します。
署名なしのビルドは中身の確認には使えますが、特権ヘルパーを登録できないため、ON / OFF の動作確認には使えません。

ヘルパーの動作確認には、`/Applications` に置いた署名済みビルドを使います。初めて ON にしたときに LaunchDaemon が
登録されます。**システム設定 > 一般 > ログイン項目と機能拡張** で Awake を許可してから、もう一度 ON にしてください。

## テスト

```bash
xcodebuild \
  -project Awake.xcodeproj \
  -scheme Awake \
  -configuration Debug \
  -destination 'platform=macOS' \
  test
```

特権操作、プロセス強制終了、再起動、蓋閉じ、Intel / Apple シリコンでの手順は
[`docs/TESTING.md`](docs/TESTING.md) にあります。これらはシステム全体の電源設定を変更したりプロセスを終了させたり
するため、自動テストでは実行しません。

## 運用上の注意

- 署名済みのアプリは `/Applications` にインストールしてください。起動時から利用可能である必要がある
  `SMAppService` デーモンについて、Apple はこの配置を推奨しています。
- `pmset disablesleep` はシステム全体の設定を変更し、root 権限が必要です。この操作を行うのは組み込みのヘルパーだけです。
- バッテリー保護と温度保護はユーザー側のアプリで動作します。アプリを強制終了しても、root 側で復旧処理が働きます。
- アイドルアサーションはユーザー操作がないことによるスリープを防ぎます。蓋を閉じたときのスリープを防ぐには、
  さらに特権が必要な `pmset disablesleep` の設定が必要です。
- `disablesleep` は Apple の公開 `pmset` マニュアルに記載されていません。対応する macOS とハードウェアの組み合わせごとに、
  リリース前に手動テストで確認してください。
- アンインストールは、メニュー下部の **アンインストール…** から行います。Awake を OFF にしてスリープ設定を元に戻し、
  ヘルパーとログイン項目の登録、保存した設定を削除して、`Awake.app` をゴミ箱に移動します。root 所有の空ディレクトリ
  `/var/db/jp.co.seeds-std.Awake` は残ります。

## トラブルシューティング

### ON にできない（ヘルパーが起動しない）

ヘルパーを登録したまま `Awake.app` を別のビルドで置き換えると、登録が古いアプリを指したままになり、
launchd がヘルパーを起動できなくなることがあります。システムログには次のように記録されます。

```text
Could not find and/or execute program specified by service: 3: No such process: Contents/MacOS/AwakeHelper
```

現在のアプリは、この状態を検出すると起動時や ON にしたときに自動で登録し直します。それでも直らない場合は、
次の順に試してください。

1. メニューの **アンインストール…** でヘルパーの登録を削除する
2. 同じバンドル ID の古いコピー（ゴミ箱、マウント中の DMG、`build/` 以下のビルドなど）を片付ける
3. `/Applications` に Awake を入れ直し、ON にしてログイン項目で許可する

ヘルパーの状態は次のコマンドで確認できます。`state = running` であれば正常です。

```bash
launchctl print system/jp.co.seeds-std.Awake.Helper
```

最終手段として、バックグラウンド項目の登録データベースをリセットして再起動する方法があります。
ほかのアプリのバックグラウンド項目の許可もすべてリセットされるので注意してください。

```bash
sudo sfltool resetbtm
```

## 参考資料

- [Apple Service Management](https://developer.apple.com/documentation/servicemanagement/)
- [Apple: Getting Started with SMAppService](https://developer.apple.com/forums/thread/802443)
- [Apple: Validating the signature of an XPC process](https://developer.apple.com/forums/thread/681053)
- [Original tanabee/awake](https://github.com/tanabee/awake)
