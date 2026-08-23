# makoto2

Mastodon サーバー「[キュアスタ！](https://precure.ml)」で稼働する AI マスコットボット **MAKOTO**（[@makoto](https://precure.ml/@makoto)）の作り直し。

旧実装 [pooza/makoto](https://github.com/pooza/makoto)（アーカイブ済み）のコードは引き継がず、機能を 4 つ（曲紹介 / 朝挨拶 / チャットボット / 11 月 4 日のバースデーライブ）に絞って作り直す。

**[v0.2.2](https://github.com/pooza/makoto2/releases/tag/v0.2.2) をリリース済み**（11 月 4 日バースデーライブと、無人で動かすための土台）。✅ **本番で稼働中。**⚠ **日常運用の 2 機能（曲紹介・朝挨拶）とチャットボットは未実装。**

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
bin/makoto whoami    # Mastodon のアカウントを表示（投稿はしない）
bin/makoto post TEXT # 投稿する
bin/makoto corpus import   # 台詞コーパスを投入する（何度実行してもよい）
bin/makoto corpus stat     # 投入済みコーパスの件数
bin/makoto track import    # 曲データを投入する（何度実行してもよい）
bin/makoto message import PATH --prune  # 原稿・台本をファイルから取り込む
bin/makoto live setlist --date=2026-11-04 --mc  # ライブの並びを下見する（投稿しない）
```

死活監視はここを叩く。⚠⚠ **終了コードで返す。**

```sh
bin/makoto status    # 0 健全 / 1 異常（復旧させる）/ 2 警告（人が見る）
```

⚠ **`2` で復旧を叩かせないこと。**孤児プロセスは再起動の瞬間に一時的に 2 本になりうるので、**検知 → 再起動 → 検知のループ**になる。⚠⚠ **投稿の失敗（`posting`）も `2`** — **トークンの失効も設定の欠落も、常駐を入れ直しても直らない。**

⚠ **`jobs` は「登録された本数」で「出た本数」ではない。**投稿が実際に出ているかは `posting` の行を見る。⚠⚠ **原稿が無い日は投稿しないのが正常**なので、`never posted` は異常ではない。

箱の外（Uptime Kuma など）からは HTTP で叩く。⚠ **常駐の中で開くので、常駐が落ちれば口も閉じる。**

```sh
curl http://127.0.0.1:4567/healthz           # 生死・ハートビート・登録本数（＝ 1）
curl http://127.0.0.1:4567/healthz/posting   # 投稿が続けて落ちていないか（＝ 2）
curl http://127.0.0.1:4567/healthz/orphans   # 孤児プロセス（＝ 2）
```

⚠⚠ **既定は `127.0.0.1` なので、外から叩くには `config/local.yaml` に `monitor.bind` を書く。**⚠ **LAN 限定・読み取り専用の死活の口**であって、管理コンソールではない。

⚠ **`/healthz/posting` と `/healthz/orphans` に自動復旧を紐付けないこと**（`makoto status` の `2` と同じ理由）。

## 開発

```sh
bundle exec rubocop         # lint
bundle exec rake test       # テスト
bundle exec rake config:lint  # 設定のスキーマ検証
```

ログは syslog に出る（`journalctl -t makoto2`）。

## ライセンス

MIT License（[LICENSE](LICENSE)）
