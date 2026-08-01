![AirTranslate hero](docs/assets/airtranslate-readme-hero.png)

# AirTranslate

macOS向けのリアルタイム・システム音声文字起こし/翻訳アプリ。

<p align="center">
  <a href="https://github.com/himomohi/AirTranslate/releases/latest/download/AirTranslate.dmg"><img alt="Download AirTranslate.dmg" src="https://img.shields.io/badge/Download-AirTranslate.dmg-2EA44F?style=for-the-badge&logo=apple&logoColor=white"></a>
  <a href="https://github.com/himomohi/AirTranslate/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/himomohi/AirTranslate?style=for-the-badge&label=Latest"></a>
  <a href="https://himomohi.github.io/AirTranslate/"><img alt="Official guide site" src="https://img.shields.io/badge/Guide-Site-0A84FF?style=for-the-badge"></a>
</p>

<p align="center">
  <a href="https://himomohi.github.io/AirTranslate/">公式ガイドサイト</a> ·
  <a href="#ダウンロード">ダウンロード</a> ·
  <a href="#必要環境">必要環境</a> ·
  <a href="#プライバシーとapiキー">プライバシー</a> ·
  <a href="README.md">English</a> ·
  <a href="README.ko.md">한국어</a> ·
  日本語 ·
  <a href="README.zh-CN.md">中文</a>
</p>

<p align="center">
  <img alt="macOS 26+" src="https://img.shields.io/badge/macOS-26%2B-0A84FF?style=flat-square&logo=apple">
  <img alt="Swift 6.2+" src="https://img.shields.io/badge/Swift-6.2%2B-F05138?style=flat-square&logo=swift&logoColor=white">
  <a href="LICENSE"><img alt="License: Apache 2.0" src="https://img.shields.io/badge/License-Apache%202.0-blue?style=flat-square"></a>
</p>

AirTranslateは、Macで再生されている音声をリアルタイムで文字起こしし、翻訳し、必要に応じてフローティング字幕として表示します。会議、講義、動画、インタビュー、配信など、外部マイク経由では扱いにくい音声をMacのシステムオーディオから直接処理するためのアプリです。

ユーザー向けの概要、セットアップガイド、ダウンロード導線は[AirTranslate公式ガイドサイト](https://himomohi.github.io/AirTranslate/)で確認できます。

デフォルトの処理フローはAppleフレームワークを使用します。GPT RealtimeとGemini Live Translateは任意のAPIベースモードで、対応するAPIキーを入力した場合のみ利用できます。

## AirTranslateを使う理由

- **システム音声優先:** ScreenCaptureKitでMacの再生音声を直接キャプチャします。
- **読みやすいライブ画面:** 原文と翻訳を並べて表示します。
- **フローティング字幕:** 他のアプリの上に字幕を表示できます。
- **Appleがデフォルト:** Apple SpeechとApple Translationを基本経路にします。
- **任意のAPIモード:** 必要なときだけOpenAI Realtime TranslationまたはGemini Live Translateを有効にします。
- **Keychain保存:** OpenAIとGeminiのAPIキーはユーザーが入力し、macOS Keychainに保存します。
- **プレーンテキスト履歴:** 保存済み記録はMac内の通常の`.txt`ファイルです。

![AirTranslate demo](docs/assets/airtranslate-readme-demo.gif)

> "Turn any Mac audio into live captions and translation, right where you are watching."

## 1.5.0の主な変更点

- **Apple標準モードのライフサイクルを強化:** Apple標準モードは引き続きローカル優先の既定経路です。古い開始試行から遅れて届く権限応答、warm-up、キャプチャコールバックは新しいセッションを変更できません。
- **外部停止を正常に処理:** アプリ外でmacOSのシステムオーディオキャプチャを停止しても、記録を保存してセッションを解除し、再開できます。
- **無音の入力欠落を防止:** 音声入力のbackpressureは黙って破棄せず、ユーザーに見える制御された停止として扱います。
- **任意のGPT文字起こし:** OpenAI APIキーを指定した場合だけ、`gpt-live-transcribe`で原文字幕を作成できます。GPTライブ翻訳とは別のモードです。

詳細は[AirTranslate 1.5.0リリースノート](https://github.com/himomohi/AirTranslate/releases/tag/v1.5.0)をご覧ください。

## 1.4.2の主な変更点

- **マイク権限の要求を安定化:** 署名済みのローカルおよびリリースビルドに、macOSのマイク権限要求に必要なaudio-inputエンタイトルメントを含めます。
- **リリース署名の検証:** 配布前にHardened Runtime、リリース/デバッグ用エンタイトルメントの分離、マイク権限説明をパッケージング検査で確認します。

詳細は[AirTranslate 1.4.2リリースノート](https://github.com/himomohi/AirTranslate/releases/tag/v1.4.2)をご覧ください。

## 1.4.1の主な変更点

- **より安定した翻訳音声:** Apple標準モードは、ストリーミング翻訳文が安定した文境界に到達してから読み上げます。
- **最後の文も読み上げ:** 句読点なしで届いた最終翻訳も、翻訳リクエスト完了時にすぐ音声出力します。
- **繰り返し末尾の抑制:** 短く書き換わってから復元された文末、ほぼ同じ確定版、短い重複接尾部分を再度読み上げません。
- **すっきりした吹き替え切替:** 翻訳音声を有効にしたとき、すでに表示されていた翻訳文を読み直しません。
- **正当な繰り返しは維持:** 短いリプレイ防止時間を過ぎた実際の繰り返しフレーズは、同じセッション内でも再度読み上げられます。
- **集中的な回帰テスト:** 翻訳音声の進行ロジックを専用のAirTranslateCoreテストで検証します。

詳細は[AirTranslate 1.4.1リリースノート](https://github.com/himomohi/AirTranslate/releases/tag/v1.4.1)をご覧ください。

## 主な機能

- Macシステム音声のリアルタイムキャプチャ
- Apple Speechによる文字起こし
- Apple Translationによる翻訳
- 原文だけに集中できるTranscribe Onlyモード
- 内蔵マイク、Bluetooth、AirPodsのマイク入力対応
- OpenAI Realtime TranslationによるGPTモード
- 原文字幕用の任意の`gpt-live-transcribe` GPT文字起こしモード
- Gemini 3.5 Live Translateモード
- APIベースの翻訳ストリーム用LIVE翻訳モード
- Apple標準モードの元言語自動検出は、言語切替の安定性改善のため一時的に無効化
- マイク入力の安定性改善（重複入力と切替時ノイズの抑制）
- 原文/翻訳言語のワンクリック入れ替え
- フローティング字幕ウィンドウ
- macOSスペル候補に基づく記録補正
- 任意の翻訳音声出力
- 保存済み記録の確認、編集、削除、フォルダ表示
- Macの言語設定に応じた英語、韓国語、日本語、簡体字中国語UIの自動選択

## 処理モード

AirTranslateは、すばやい選択と詳細設定を分けています。

| モード | 適した用途 | 詳細 |
| --- | --- | --- |
| Apple標準モード | ローカル寄りの文字起こしと翻訳 | Apple Speechで文字起こしし、Apple Translationで選択した言語ペアを翻訳します。元言語の自動検出は、言語切替の安定性改善のため一時的に無効化されています。 |
| GPTモード | OpenAI Realtimeのライブ翻訳 | 音声をOpenAI Realtime Translationへ直接ストリーミングします。APIキーが保存されていない場合、設定モーダルを開いてAPIキー入力欄にフォーカスします。 |
| GPT文字起こし | OpenAIの原文字幕 | 任意モードでOpenAI APIキーを指定すると、`gpt-live-transcribe`で翻訳なしの原文字幕を作成します。 |
| Gemini Live | Gemini 3.5 Live Translate | 音声をGemini Live Translateへ直接ストリーミングし、返された入力/翻訳テキストを表示します。Gemini APIキーが保存されていない場合、設定モーダルを開いてキー入力欄にフォーカスします。 |
| 文字起こしのみ | 翻訳なしの原文字幕 | 翻訳を実行せず、原文の記録だけを残します。 |
| LIVE翻訳 | 翻訳ストリームを直接得たい場合 | 選択したAPIプロバイダーのライブ翻訳モデルが翻訳結果を直接生成する経路を使います。 |

GPT/Geminiモデルの詳細、APIキー入力、記録補正、音声出力は歯車の設定モーダルで管理します。メインサイドバーには重要な選択だけを残しています。

## プライバシーとAPIキー

AirTranslateには独自のバックエンドアカウントシステムはありません。

- Apple標準モードはmacOSフレームワークとApple言語アセットを使用します。
- OpenAIへのリクエストはGPTモードまたは任意のGPT文字起こしモードを有効にした場合のみ発生します。
- GeminiへのリクエストはGemini Liveモードを有効にした場合のみ発生します。
- OpenAIとGeminiのAPIキーはアプリに埋め込まず、コミットせず、リリースパッケージにも含めません。
- APIキーは`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`でmacOS Keychainに保存します。
- 保存済み記録はユーザーのMac上のプレーンテキストファイルです。

APIキーが必要な場合は、[OpenAI APIキーページ](https://platform.openai.com/api-keys)または[Google AI Studio APIキーページ](https://aistudio.google.com/app/apikey)でキーを作成し、AirTranslateの設定モーダルに貼り付けてください。

## Apple翻訳言語パック

Apple標準モードは、macOSが管理する翻訳言語アセットを使用します。新しい言語ペアでApple標準モードを使う前に、必要なApple翻訳言語パックをダウンロードしてください。

1. **システム設定**を開きます。
2. **一般 > 言語と地域**に移動します。
3. **翻訳言語**をクリックします。
4. 使いたい原文言語と翻訳先言語ごとに**ダウンロード**をクリックします。
5. 任意: 対応する翻訳を可能な限りMac上で処理したい場合は、**オンデバイスモード**をオンにします。

選択した言語ペアが利用できない、またはまだダウンロードされていない場合、macOSに必要な言語アセットが準備されるまでApple標準モードの翻訳が開始されない、または利用不可の状態が表示されることがあります。

## 権限

AirTranslateは、キャプチャと文字起こしに必要な権限だけを要求します。

- 画面収録
- システムオーディオ録音
- 音声認識

ScreenCaptureKitのシステム音声キャプチャ経路を使うため、画面収録権限が必要です。AirTranslateは画面フレームを録画ファイルとして保存しません。

macOSのプライバシー権限を変更した後は、アプリを終了して再起動すると新しい権限状態が安定して反映されます。

## ダウンロード

最新のオープンソースビルドは[GitHub Releases](https://github.com/himomohi/AirTranslate/releases/latest)からダウンロードできます。DMGが最も簡単なインストール方法で、ZIPも軽量な配布形式として引き続き利用できます。

- [AirTranslate.dmgをダウンロード](https://github.com/himomohi/AirTranslate/releases/latest/download/AirTranslate.dmg)
- [AirTranslate-1.5.0.zipをダウンロード](https://github.com/himomohi/AirTranslate/releases/latest/download/AirTranslate-1.5.0.zip)
- [AirTranslate.dmg.sha256をダウンロード](https://github.com/himomohi/AirTranslate/releases/latest/download/AirTranslate.dmg.sha256)
- [バージョン履歴を見る](Release/VERSION-HISTORY.md)

リリースDMGとZIPは、オープンソース配布用のad-hoc署名ビルドです。まだApple notarization済みの配布ではないため、初回起動時にmacOSが「開発元を確認できません」という警告を表示する場合があります。

1. DMGを開き、`AirTranslate.app`をApplicationsフォルダへドラッグします。
2. Applicationsで`AirTranslate.app`をControlクリックまたは右クリックします。
3. **開く**を選び、macOSの警告ダイアログでもう一度**開く**を選びます。

ダウンロードしたDMGのチェックサムは次のように確認できます。

```bash
shasum -a 256 AirTranslate.dmg
cat AirTranslate.dmg.sha256
```

## 必要環境

- macOS 26.0以降
- Swift 6.2以降
- システム音声キャプチャに対応したMac
- Apple SpeechとApple Translationフレームワークが利用できる環境
- 任意: GPTモード用のOpenAI APIキー
- 任意: Gemini Liveモード用のGemini APIキー

## ソースからビルド

アプリバンドルを実行:

```bash
./script/build_and_run.sh
```

ビルドして起動確認:

```bash
./script/build_and_run.sh --verify
```

ログを表示:

```bash
./script/build_and_run.sh --logs
```

開発中に権限をリセット:

```bash
./script/build_and_run.sh --reset-permissions
```

SwiftPMチェック:

```bash
swift build
swift test
```

## 基本的な使い方

1. 原文言語と翻訳言語を選びます。
2. 方向を逆にしたい場合は中央の言語入れ替えボタンを押します。
3. Apple標準モード、GPTモード、またはGemini Liveを選びます。
4. APIベースモードで案内が出たら、設定モーダルにOpenAIまたはGemini APIキーを入力します。
5. 開始ボタンを押します。
6. Macで会議、講義、動画、インタビュー、配信音声を再生します。
7. メイン画面またはフローティング字幕で原文と翻訳を確認します。
8. 停止すると現在の記録が保存されます。

## 保存済み記録

保存済み記録はプレーンテキストファイルとして保存されます。

```text
~/Library/Application Support/AirTranslate/Transcripts/*.txt
```

原文と翻訳を一緒に保存する場合、`_original.txt`と`_translation.txt`に分けて保存し、アプリのライブラリUIでは1つの項目として表示します。

## プロジェクト構成

```text
Package.swift
Resources/
  AppIcon.png
  AppIcon.icns
Sources/AirTranslate/
  App/
  Models/
  Services/
  Support/
  Views/
Sources/AirTranslateCore/
Tests/
script/
  build_and_run.sh
docs/assets/
  airtranslate-readme-hero.png
```

## 主要な実装領域

- `SystemAudioCapture`: ScreenCaptureKitでMacのシステム音声をキャプチャします。
- `LiveSpeechTranscriber`: Apple Speechによる文字起こしをストリーミングします。
- `AppleTranslationService`: Apple Translationの処理を分離します。
- `OpenAIRealtimeTranscriber`: 任意のOpenAIリアルタイム翻訳と文字起こしイベントを処理します。
- `GeminiLiveTranslationService`: 任意のGemini Live Translate WebSocketセッションを処理します。
- `OpenAIAPIKeyStore` / `GeminiAPIKeyStore`: APIキーをmacOS Keychainに保存します。
- `TranslationSessionStore`: キャプチャ、記録状態、翻訳、保存、音声出力を調整します。
- `SidebarView`: 言語、処理方式、セッション、設定への入口を提供します。
- `CaptionBoardView`: ライブ記録、翻訳、操作、オーディオメーターを表示します。
- `TranscriptLibraryView`: 保存済み記録を管理します。
- `FloatingCaptionWindowController`: フローティング字幕ウィンドウのライフサイクルを管理します。

## ライセンス

AirTranslateは[Apache License 2.0](LICENSE)の下で公開されています。著作権表示は[NOTICE](NOTICE)にあります。

AirTranslateは独立したオープンソースプロジェクトであり、Apple、OpenAI、Googleとは提携していません。
