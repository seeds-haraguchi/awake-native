# 開発・リリース手順

この文書は Awake のソースからビルドする人と、配布用 DMG を作る人向けです。アプリのインストール方法は[利用ガイド](user-guide-ja.md)を参照してください。

## 前提

- macOS 13 以降、Xcode 16 以降
- 補助プログラムの登録を試す場合は、アプリと補助プログラムを同じ Apple Developer チームで署名できる環境
- 配布用 DMG を作る場合は、Developer ID Application 証明書と、キーチェーンに保存した公証用 `notarytool` プロファイル

Team ID は署名に含まれる公開の識別子で、パスワードや秘密鍵ではありません。現在のチームの値は Xcode プロジェクトとビルドスクリプトに設定されています。公証のパスワードや証明書の秘密鍵はリポジトリに置かないでください。

## 構成

```text
Awake.app
  macOS/AwakeApp/       メニューバー、状態管理、補助プログラムとの通信
  macOS/AwakeCore/      スリープ抑止、電源・温度の監視、安全ポリシー
  macOS/AwakeShared/    アプリと補助プログラムに共通の識別子と XPC プロトコル
  macOS/AwakeHelper/    root 権限での pmset 操作と復旧
  macOS/AwakeTests/     安全ポリシーと状態解析のテスト
```

アプリ本体がアイドルスリープ抑止を保持し、補助プログラムが蓋を閉じたときのスリープ設定を変更します。補助プログラムは XPC 接続の切断やハートビートの途絶を検出して設定を戻し、復旧に失敗した場合は再試行します。XPC 接続相手はバンドル ID と署名チームで制限しています。

`pmset disablesleep` は Apple の公開 `pmset` マニュアルに記載されていません。リリース前に、対象の macOS と Mac の組み合わせで蓋閉じ・復旧を実機確認してください。[実機テストの手順](TESTING.md)を参照してください。

## ビルドとテスト

署名なしでコンパイルと Universal 2 の構成だけを確認する場合は、次を実行します。

```bash
./scripts/build-universal.sh
```

`build/Awake-unsigned.app` ができます。署名なしのアプリでは補助プログラムを登録できず、ON / OFF の動作確認はできません。

補助プログラムも含めて動作確認する場合は、開発用証明書で署名します。

```bash
./scripts/build-development.sh
```

`build/Awake.app` を `/Applications` にコピーしてから起動し、macOS の「バックグラウンドでの実行」を許可してください。署名チームを切り替える場合は、ビルドスクリプトの `DEVELOPMENT_TEAM` にチーム ID を渡します。

自動テストは次のコマンドで実行します。システム全体の電源設定を変更する実機テストは含みません。

```bash
xcodebuild -project Awake.xcodeproj -scheme Awake -configuration Debug -destination 'platform=macOS' test
```

## 配布用 DMG

配布用の Mac に Developer ID Application 証明書を用意し、Apple の `notarytool` で公証用の認証情報をキーチェーンに保存します。`NOTARY_PROFILE` には保存したプロファイル名を指定します。

```bash
NOTARY_PROFILE=AwakeNotary ./scripts/release-notarized-dmg.sh
```

スクリプトは Universal 2 アプリを署名し、アプリと DMG を公証して検証します。出力先は `build/distribution/` です。ビルド番号にコミット数を使うため、未コミットの変更があると中断します。完成した DMG は内容と実機での動作を確認してから GitHub Releases に登録してください。

## 組織の Apple Developer チームへ移行するとき

現在は Xcode プロジェクトと `scripts/build-development.sh`、`scripts/release-notarized-dmg.sh` に既存チームの ID が設定されています。組織のチームが利用可能になったら、これらの設定を一緒に更新し、アプリと補助プログラムを同じチームで署名してください。XPC の署名要件は実行中のバイナリからチーム ID を取得します。

チームを変えたビルドで、既存インストールの上書き更新が正しく働くかは未確認です。公開前に、補助プログラムの再登録、ON / OFF、設定の復旧、アンインストールを実機で確認してください。

参考: [Apple Service Management](https://developer.apple.com/documentation/servicemanagement/)、[Apple Notary Service](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
