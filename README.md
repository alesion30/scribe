# scribe

マイクとシステム音声を録音し、[whisper.cpp](https://github.com/ggml-org/whisper.cpp) でローカルに文字起こしする macOS 向けのコマンドラインツール。処理はすべて端末内で完結し、データが外部に送られることはない。

## 機能

- **マイクとシステム音声の同時録音** — ScreenCaptureKit（macOS 15 以降）で両方を同時に取り込む
- **ローカル文字起こし** — whisper.cpp を Metal GPU アクセラレーション付きで端末内実行
- **逐次出力** — 文字起こしはデコードできたセグメントから順に書き出すので、長いファイルでも進捗が見え、途中で止めてもそこまでの結果が残る
- **確認付きの停止** — 録音は `q` を押して `y` で確定するまで止まらない。Ctrl+C はいつでも実行を中断し、録音と書き出し済みの転写を残す
- **柔軟なワークフロー** — 録音と文字起こしを一度に実行することも、個別に実行することもできる
- **録音の自動削除** — 文字起こしが済んだ録音は既定で削除する。残したいときは `--keep-audio` か `-w` を使う
- **時間範囲の文字起こし** — ファイルを切り出さずに、指定した区間だけを文字起こしできる
- **長時間録音への対応** — 長い音声を分割し、無音は VAD で飛ばすので、静かな区間で同じ行を繰り返さない
- **言語判定** — 自動判定、または ISO 639-1 コードでの明示指定
- **タイムスタンプ付き出力** — プレーンテキストのほか、セグメントごとの時刻を持つ SRT / WebVTT を出力できる
- **モデル管理** — whisper モデルのダウンロード・一覧・削除を CLI から実行

## 動作要件

- macOS 15.0 (Sequoia) 以降
- 画面収録の権限（システム設定 > プライバシーとセキュリティ > 画面収録とシステムオーディオ録音）
- 録音するコマンド（`scribe` と `scribe record`）は停止キーを標準入力から読むため、端末上で実行する必要がある

ソースからビルドする場合は、あわせて次が必要になる。

- Xcode 16 以降（ScreenCaptureKit などの SDK に必要）
- Swift 6.0 以降（`Package.swift` の `swift-tools-version: 6.0` が要求する下限）

このリポジトリでは、再現性のために `mise.toml` でビルド用の Swift ツールチェーンを 6.3 に固定している（`mise install` で導入される）。ビルド自体は Swift 6.0 以降であれば通るので、この固定は下限の引き上げではなく、開発環境をそろえるためのもの。

## インストール

### mise で導入する（推奨）

[mise](https://mise.jdx.dev/) が入っていれば、リリース版のバイナリを 1 コマンドで導入できる。mise 自体の導入方法は[公式のインストール手順](https://mise.jdx.dev/installing-mise.html)を参照。

```bash
mise use -g "github:Alesion30/scribe"
scribe --help
```

更新は `mise upgrade` で行う。

### ビルド済みバイナリを手動で展開する

[リリースページ](https://github.com/Alesion30/scribe/releases)から `scribe-macos-<arch>.tar.gz` をダウンロードする。tarball は `whisper.framework` を同梱した自己完結型なので、展開するだけで使える。

```bash
tar xzf scribe-macos-arm64.tar.gz
./scribe-macos-arm64/scribe --help
```

バイナリは自身の位置（`@loader_path`）を起点に `whisper.framework` を探すため、移動するときは同じディレクトリに置いたままにする。

### ソースからビルドする

ビルドに使う Swift ツールチェーンは `mise.toml` で固定してある。mise が未導入なら[公式のインストール手順](https://mise.jdx.dev/installing-mise.html)に従って入れる。

```bash
git clone https://github.com/Alesion30/scribe.git
cd scribe
mise install       # mise.toml に固定した Swift ツールチェーンを導入
mise run build     # swift build -c release
```

ビルドしたバイナリは `.build/release/scribe` に置かれる。動作確認と、`$PATH` の通ったディレクトリへの配置は次のとおり。

```bash
.build/release/scribe --help
cp .build/release/scribe /usr/local/bin/
```

ScreenCaptureKit などの Apple フレームワークの SDK は Xcode に含まれるものを使うため、mise とは別に Xcode 16 以降が必要になる。

利用できるタスクは `mise tasks` で一覧できる。

### モデルのダウンロード

scribe は whisper.cpp 互換のモデル（GGML 形式）を必要とする。設定されているモデルが標準モデル（[利用可能なモデル](#利用可能なモデル)を参照）で、まだダウンロードされていない場合、初回実行時に自動ダウンロードを提案するので、事前準備は必須ではない。

先にダウンロードしておく場合は次のようにする。

```bash
# 標準モデルは URL の指定が不要（既定: large-v3-turbo, 約 1.5 GB）
scribe model download large-v3-turbo

# 軽量な選択肢（約 141 MB、高速だが精度は落ちる）
scribe model download base

# 任意の URL から独自モデルを取得することもできる
scribe model download my-model -u https://example.com/ggml-my-model.bin
```

モデルは `~/.scribe/models/` に保存される。

## 使い方

### 録音して文字起こしする（既定動作）

```bash
# 録音し、q → y で止めた時点で文字起こしする
scribe

# モデルと言語を指定する
scribe -m base -l ja

# 録音を残す（既定では文字起こしが済んだ時点で削除される）
scribe --keep-audio

# 保存先を指定して録音を残す
scribe -w recording.wav

# 文字起こし結果を標準出力ではなくファイルに書き出す
scribe -o transcript.txt

# プレーンテキストではなく SRT 字幕として書き出す
scribe -f srt -o transcript.srt
```

録音は文字起こしのための中間ファイルなので、転写を書き終えた時点で削除する。残したいときは `--keep-audio` を付けるか、`-w` で保存先を指定する。

削除の対象は scribe が `~/.scribe/recordings/` に自動生成した WAV だけ。録音に失敗したとき、無音だったとき、文字起こしが失敗したとき、Ctrl+C で中断したときは削除せず、復旧や再実行に使える状態で残す。削除できなかった場合は、文字起こしが済んでいることと残っている WAV のパスをエラーとして表示する。

### 録音を止める

録音中に効くキーは 2 つ。

| キー | 動作 |
|---|---|
| `q` → `y` | 録音を終えて次に進む（既定動作なら文字起こし） |
| `Ctrl+C` | 実行そのものを終える |

`q` は確認を出すだけで、録音は止まらない。`y` を押すまで録音は続くので、押し間違えても `n` か `Esc` で元に戻れる。

```
Recording... Press q to stop, Ctrl+C to abort.
Stop recording? Press y to stop, n or Esc to keep recording.
Still recording... Press q to stop, Ctrl+C to abort.
```

Ctrl+C はどこで押しても実行を終える。録音中なら、そこまでの音声を WAV にまとめてパスを表示してから終了する。文字起こし中なら、そこまでに書き出した転写と、元の WAV を残して終了する。どちらも終了コードは 130。

```
Aborted. Recording kept at: ~/.scribe/recordings/2025-01-15_14-30-00.wav (14:30:00 → 14:52:10, 22m 10s)
```

停止キーは標準入力から読むので、`scribe` と `scribe record` は端末上で実行する必要がある。パイプやリダイレクトで標準入力が端末でない場合は、録音を始める前にその旨を表示して終了する。端末を持たない環境で使うなら、録音済みのファイルを渡す `scribe transcribe` を使う。

### 録音だけする

```bash
# 録音して WAV として保存する（文字起こしはしない）
scribe record -o meeting.wav

# システム音声のみ（マイクを使わない）
scribe record --no-mic

# マイクのみ（システム音声を取り込まない）
scribe record --no-system
```

`scribe record` は録音そのものが目的なので、WAV は削除しない。`scribe transcribe` も、指定された入力ファイルには手を付けない。

### 既存のファイルを文字起こしする

```bash
# WAV ファイルを文字起こしする
scribe transcribe recording.wav

# モデルと言語を指定する
scribe transcribe recording.wav -m large-v3-turbo -l ja

# ファイルの一部だけを文字起こしする（10:00 から 180 秒間）
scribe transcribe recording.wav --start 600 --duration 180

# 10:00 からファイルの終わりまで
scribe transcribe recording.wav --start 600

# プレーンテキストではなく WebVTT として書き出す
scribe transcribe recording.wav -f vtt

# 無音を飛ばさず、音声をそのまま whisper に渡す
scribe transcribe recording.wav --no-vad
```

### 長時間の録音

whisper は音声のスペクトログラムを、渡された範囲全体の最大フレームを基準に正規化し、そこから 80 dB 下を床に丸める。1 時間分を一度に渡すと大きな音がひとつあるだけで残りが床に沈み、デコーダはそれ以降ずっと同じ行を繰り返す。長い無音があるとデコードの手がかりがなくなり、さらに起きやすくなる。

scribe は既定でこの両方を避ける。

| オプション | 既定値 | 説明 |
|---|---|---|
| `--chunk-length <seconds>` | `600` | whisper 1 回あたりに渡す音声の長さ。正規化がこの範囲に閉じる。`0` にすると分割せず全体を渡す |
| `--vad` / `--no-vad` | 有効 | Silero VAD で無音を飛ばす。タイムスタンプは元の音声を指したまま変わらない |

VAD モデル（約 865 KB）は初回利用時に `~/.scribe/models/` へダウンロードされる。文字起こし用のモデルではないので `scribe model list` には出ない。

同じ行が連続した場合は最初の 1 件だけを残す。分割と VAD をすり抜けたループがあっても、残りの文字起こしが埋もれない。

### 出力形式

`--format` / `-f` で文字起こしの出力形式を選べる（既定: `txt`）。

| 形式 | 説明 |
|---|---|
| `txt` | セグメントごとに 1 行、タイムスタンプなし |
| `srt` | SubRip 字幕。通し番号と `HH:MM:SS,mmm` 形式の区間を持つ |
| `vtt` | WebVTT 字幕。`WEBVTT` ヘッダと `HH:MM:SS.mmm` 形式の区間を持つ |

タイムスタンプは音声の先頭からの経過時間。`--start` で一部だけを文字起こししたときも元ファイルの時刻のままなので、`--start 600` で作った字幕はそのまま元ファイルに重ねられる。

```
$ scribe transcribe meeting.wav -l ja -f srt
1
00:00:00,000 --> 00:00:03,320
次の会議は明日の午後3時から始まります。

2
00:00:03,320 --> 00:00:07,800
今日はとても良い天気ですね。
```

### 文字起こしの出力

セグメントは whisper がデコードした順に出力先へ追記されるので、長い録音でも処理中から結果を読める。

```bash
scribe transcribe meeting.wav -o transcript.txt
tail -f transcript.txt    # 別のシェルから
```

逐次書き出しの結果として、次の 2 点がある。

- 実行が失敗したり途中で中断したりしても、そこまでにデコードした分はファイルに残る
- 出力先はコマンド開始時に切り詰められる（シェルの `>` によるリダイレクトと同じ挙動）

文字起こしをファイルに出力する場合は、進捗率が標準エラー出力に表示される。既定の標準出力へ出す場合は、文字起こし結果自体が進捗になるため表示しない。

### モデルを管理する

```bash
# ダウンロード済みのモデルを一覧する
scribe model list

# 標準モデルを名前だけでダウンロードする
scribe model download <name>

# 任意の URL から独自モデルをダウンロードする
scribe model download <name> -u <url>

# モデルを削除する
scribe model remove <name>
```

### 詳細ログを出す

どのコマンドにも `-v` / `--verbose` を付けると、標準エラー出力に詳細なログが出る。

```bash
scribe -v -m base
```

## 設定

scribe の設定は階層的に解決される。優先度は高い順に次のとおり。

1. CLI のフラグ
2. 設定ファイル（`~/.scribe/config.json`）
3. 組み込みの既定値

### 設定ファイル

`~/.scribe/config.json` を作ると、既定値を永続化できる。

```json
{
  "model": "large-v3-turbo",
  "language": "auto",
  "format": "txt",
  "recordingDir": "~/.scribe/recordings",
  "vad": true,
  "chunkLength": 600,
  "noMic": false,
  "noSystem": false
}
```

すべての項目は任意。JSON Schema を [`schema/config.schema.json`](schema/config.schema.json) に用意してある。

### 環境変数

| 変数 | 説明 |
|---|---|
| `SCRIBE_HOME` | ベースディレクトリを上書きする（既定: `~/.scribe`） |

### ディレクトリ構成

```
~/.scribe/
├── config.json        # 設定ファイル（任意）
├── models/            # ダウンロードした whisper モデル
│   ├── base.bin
│   └── silero-v5.1.2.bin   # VAD モデル（初回利用時に取得）
└── recordings/        # 保存した録音データ
    └── 2025-01-15_14-30-00.wav
```

録音ファイル名には録音を開始した時刻が入る。長時間の録音でも、ファイル名からどのセッションかを判別できる。録音を残した場合は、保存先と録音の全体の範囲を表示する。

```
Recording saved to: ~/.scribe/recordings/2025-01-15_14-30-00.wav (14:30:00 → 16:37:48, 2h 7m 48s)
```

既定動作で文字起こしまで済ませた場合、この WAV は削除され、範囲だけを表示する。

```
Recording deleted after transcription (14:30:00 → 16:37:48, 2h 7m 48s)
```

### クラッシュリカバリ

録音中の音声は、入力ソースごとに 1 ファイルずつディスクへ書き出している。

```
recordings/
├── 2025-01-15_14-30-00.mic.wav
└── 2025-01-15_14-30-00.system.wav
```

録音を停止すると、これらは `2025-01-15_14-30-00.wav` にミックスされて削除される。scribe が強制終了したりマシンの電源が落ちたりした場合は、直前の 1 秒までを収めた再生可能な WAV としてそのまま残るので、次のように直接文字起こしできる。

```bash
scribe transcribe ~/.scribe/recordings/2025-01-15_14-30-00.mic.wav
```

ミックス後の WAV も、既定動作で文字起こしが済めば削除される。文字起こしを終える前に落ちた場合は残るので、そこから再開できる。

## 権限

初回実行時に、macOS が次の権限を求める。

| 権限 | 用途 | 設定場所 |
|---|---|---|
| 画面収録とシステムオーディオ録音 | システム音声の取り込み | システム設定 > プライバシーとセキュリティ > 画面収録とシステムオーディオ録音 |
| マイク | マイク入力の取り込み | システム設定 > プライバシーとセキュリティ > マイク |

権限は、scribe を起動したターミナルアプリ（Terminal、iTerm2 など）に対して許可する。

画面収録の権限がないと、ScreenCaptureKit はエラーを返さず応答しなくなる。scribe は 10 秒待って応答がなければ設定場所を示して終了するので、録音中に見えたまま何も録れていない状態にはならない。システム音声が不要なら `--no-system` で回避できる。

## 利用可能なモデル

| モデル | サイズ | 特徴 |
|---|---|---|
| `tiny` | 約 74 MB | 最速だが精度は最も低い |
| `base` | 約 141 MB | 動作確認向け |
| `small` | 約 465 MB | 速度と精度のバランス型 |
| `medium` | 約 1.4 GB | 精度重視 |
| `large-v3-turbo` | 約 1.5 GB | 速度と精度のバランスが最も良い（既定） |
| `large-v3` | 約 2.9 GB | 最も精度が高い |

これらの標準モデルは名前だけでダウンロードできる（`scribe model download <name>`）。実体は [Hugging Face](https://huggingface.co/ggerganov/whisper.cpp/tree/main) で `ggml-*.bin` として公開されているもの。

無音の読み飛ばしにはこれとは別に `silero-v5.1.2`（約 865 KB、[ggml-org/whisper-vad](https://huggingface.co/ggml-org/whisper-vad) 提供）を使う。`--no-vad` を付けない限り自動で取得される。

## 開発

### テスト

ユニットテストと結合テストは `Tests/scribeTests/` にある。

```bash
mise run test    # swift test
```

結合テスト（`TranscriptionIntegrationTests`）は日本語の WAV フィクスチャを実際の `WhisperContext` に通し、文字起こしパイプラインのリグレッションを検出する。設定されている whisper モデルがローカルにない場合は自動的にスキップされるので、クローン直後でもテストは失敗しない。

結合テストで使うモデルを変えるには次のようにする。

```bash
SCRIBE_TEST_MODEL=base mise run test
```

### Lint

SwiftLint の設定は `.swiftlint.yml` にある。現状は違反ゼロなので、何か報告されたらそれは変更が持ち込んだもの。

```bash
mise run lint                  # swiftlint lint --strict。警告も失敗扱いになる
mise exec -- swiftlint --fix   # 自動修正できるルールを適用する
```

長さと命名のしきい値は既定より緩めてある。信号処理のコードでは短いループ添字や長めの関数のほうが読みやすく、既定に合わせるとコードのほうが歪むため。

### CI

`.github/workflows/quality.yml` が、PR と `main` への push のたびに動く。Swift のビルドとテストは GitHub ホストの `macos-15` runner、PR タイトルの検証は `ubuntu-latest` で走る。

| ジョブ | 実行内容 |
|---|---|
| Conventional PR title | PR タイトルが Conventional Commits に沿っているかを検証する |
| Swift build and test | `swift build -c debug` のあと `mise run test`（どちらも mise の Swift 6.3） |
| SwiftLint | `mise run lint` |

squash merge のコミット subject は PR タイトルから作られ、それがリリースの採番に使われる。そのためタイトルを編集したときも検証し直す。逆にタイトルや本文だけの編集では Swift のジョブは走らせない。

ツールチェーンは runner 同梱の Xcode ではなく `mise.toml` のものを使う。`mise.lock` が checksum まで固定しているので、手元と CI が同じ Swift・同じ SwiftLint でビルドされる。`release.yml` も同じ mise の toolchain を使うので、PR が緑なのにリリースだけ落ちることはない。

runner には whisper モデルがないので `TranscriptionIntegrationTests` はスキップされ、CI ではユニットテストだけが走る。実際の文字起こしはローカルでの確認に任せる。下記のスモークテストを実行するか、`SCRIBE_TEST_MODEL` を指定して手元のモデルで結合テストを回す。

### リリース

`main` で `.github/workflows/release.yml` を `workflow_dispatch` から実行すると、バージョンの採番から Release の公開までが一度に走る。

次のバージョンは、前回のリリースタグ以降に `main` へ入ったコミットの subject から決まる。

| コミット | 上げ幅 |
|---|---|
| `feat:` | minor |
| `fix:` / `perf:` | patch |
| `!` 付き、または本文に `BREAKING CHANGE:` | major |

`docs:` や `chore:` しかない場合は、Release を作らずに理由を出して失敗する。手元で次のバージョンを確認するには `./scripts/next-version.sh` を実行する。

採番したバージョンは `Sources/scribe/Scribe.swift` に書き戻され、`chore(release): vX.Y.Z` として `main` にコミットされる。タグと Release はこのコミットを指すので、バージョン文字列を手で書き換える必要はない。

公開済みのタグと Release は書き換えない。同じタグが既にあればビルドを始める前に止まる。

コミットは GitHub App のトークンで作る。`main` の ruleset を bypass するためで、`RELEASE_APP_ID` と `RELEASE_APP_PRIVATE_KEY` の 2 つの Secret を必要とする。

### スモークテスト

リリースビルドを作り、既知のフィクスチャが期待どおり文字起こしされるかを確認する一発実行のスクリプト。

```bash
mise run smoke                                        # 既定: 天気サンプルで「天気」を探す
./scripts/smoke.sh -f path/to.wav -k expected_word    # フィクスチャと期待キーワードを変更する
./scripts/smoke.sh -h                                 # ヘルプ
```

### フィクスチャの再生成

フィクスチャは `Tests/scribeTests/Fixtures/` にコミットしてある。macOS の `say`（Kyoko の音声）で再生成するには次を実行する。

```bash
./scripts/generate-fixtures.sh
```

scribe の文字起こしパイプラインが扱う形式に合わせて、16 kHz モノラル 16 bit の WAV を書き出す。再生成した結果は macOS のバージョンによって多少バイト列が変わることがある。

## アーキテクチャ

scribe は次の技術で構成している。

- **[ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)** — `captureMicrophone` に対応した macOS の音声・画面キャプチャフレームワーク（macOS 15 以降）
- **[whisper.cpp](https://github.com/ggml-org/whisper.cpp)** — OpenAI Whisper の C/C++ 実装。XCFramework として組み込み、Metal GPU アクセラレーションを利用する
- **[Swift Argument Parser](https://github.com/apple/swift-argument-parser)** — 型安全な CLI 引数のパース
- **[Accelerate (vDSP)](https://developer.apple.com/documentation/accelerate/vdsp)** — ハードウェアアクセラレーションによる音声信号処理

## ライセンス

MIT

## 謝辞

- [OpenAI Whisper](https://github.com/openai/whisper) — 原典となる音声認識モデル
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) — 高性能な C/C++ 推論エンジン
