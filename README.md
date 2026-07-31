# makoto2

Mastodon サーバー「[キュアスタ！](https://precure.ml)」で稼働する AI マスコットボット **MAKOTO**（[@makoto](https://precure.ml/@makoto)）の作り直し。

旧実装 [pooza/makoto](https://github.com/pooza/makoto)（アーカイブ済み）のコードは引き継がず、機能を 4 つ（曲紹介 / 朝挨拶 / チャットボット / 11 月 4 日のバースデーライブ）に絞って作り直す。

**[v0.1.0](https://github.com/pooza/makoto2/releases/tag/v0.1.0) をリリース済み**（基盤の決定と土台）。⚠ **まだ稼働していない** — 4 つの機能はこれから。

- [docs/CLAUDE.md](docs/CLAUDE.md) — 開発ガイド（プロジェクトのルール・運用手順の正本）
- [docs/makoto-persona.md](docs/makoto-persona.md) — 剣崎真琴の人物設定と、MAKOTO が語ってよい範囲
- [docs/makoto-legacy.md](docs/makoto-legacy.md) — 旧実装の経緯と引き継ぐ資産（台詞コーパス）
- [docs/birthday-live.md](docs/birthday-live.md) — 11 月 4 日バースデーライブの要件
- [docs/track-corpus.md](docs/track-corpus.md) — 曲データの自動収集

## 動かす

Ruby は [.ruby-version](.ruby-version) のバージョンを使う。

```sh
bundle install
cp config/local_sample.yaml config/local.yaml   # 秘密情報はここに書く（コミットしない）
bundle exec rake migration:run
```

常駐プロセスは 1 本だけで、投稿のスケジュールはその中で回す。

```sh
bin/makoto_daemon.rb start|stop|restart|status
```

運用操作は CLI のサブコマンドで行う（管理コンソールは作らない）。

```sh
bin/makoto version   # バージョンと実行環境
bin/makoto config    # 設定（秘密情報はマスクされる）
bin/makoto status    # 常駐プロセスの生死。落ちていれば exit 1
bin/makoto whoami    # Mastodon のアカウントを表示（投稿はしない）
bin/makoto post TEXT # 投稿する
bin/makoto corpus import   # 台詞コーパスを投入する（何度実行してもよい）
bin/makoto corpus stat     # 投入済みコーパスの件数
```

## 開発

```sh
bundle exec rubocop         # lint
bundle exec rake test       # テスト
bundle exec rake config:lint  # 設定のスキーマ検証
```

ログは syslog に出る（`journalctl -t makoto2`）。

## ライセンス

MIT License（[LICENSE](LICENSE)）
