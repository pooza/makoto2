---
name: sync
description: セッション開始時の進捗同期。「進捗を同期してください」「同期して」などで起動する。リモート・実機（bydo / rubicon）・Dependabot・Codex レビュー・Sentry・chubo2・ginseng-*・cure-api・マイルストーン・曲データの収集・誕生日の原稿・pooza/hadlar との往復を確認して報告する。
---

# セッション開始時の同期手順

⚠ **この手順の正本はこのファイル**（#300 で `docs/CLAUDE.md` の「セッション開始時の同期手順」から移した）。`docs/CLAUDE.md` の同名の節はポインタ。
**「なぜそうするか」と踏んだ記録は `docs/CLAUDE.md` に残してある**（各段の「→」の先）。手順を足すときはここだけを直す。

🔴 **この手順の本体は読むだけ。**外へ書く段（コメント・返信・👍・起票・マージ・マイルストーンの書き換え）は、**読んだ結果を報告して判断を仰いでから**行う。⚠ 例外は段ごとに書いてある（cure-api の眠っている PR のマージなど、オーナーが同期の中でやると決めたもの）。

報告は日本語で書く。判断を仰ぐ問いも日本語。

## 1. 読む

- `docs/CLAUDE.md` を読む（`MEMORY.md` は自動で読まれるので、両者の食い違いを意識する）
- ⚠ **前のセッションの締めを読む**（メモリの経過ログ）。「次は〜」と書いてあれば、そこが前提の答え合わせになる

## 2. リモート

```sh
git fetch origin                       # 🔴 最初に必ず。リモートが正本で、ローカルを信用しない
git log HEAD..origin/develop --oneline
git log --oneline -10
gh issue list --state open
gh pr list --state open
gh pr list --repo pooza/makoto-scripts --state open   # 原稿の正本（private）
```

## 3. 実機（`bydo` / `rubicon`）

```sh
.claude/skills/sync/scripts/hosts.sh   # 読むだけ
```

見るのは 3 つ: **置いてあるもの**（チェックアウト）・**動いているもの**（`bin/makoto status` の `revision` ＝ 常駐が起動時に読んだもの）・**その版の枠の本数**（`jobs: 7`）。⚠ `DropInPaths` は空であること（#174）。

- 🔴 **`makoto status` の `error:` 行が出たら 🔴 で終了コード 1**（#559 — 生きていても、投稿の見送りや heartbeat の古さは error で出る）。⚠ `warning:` 行は ⚠ を出すだけ

- 🔴 **`revision` とチェックアウトが違えば、次に見るのは差分の中身**（`git log <revision>..<checkout> --name-only`）。⚠⚠ **再起動を省いてよいのは差分が `docs/` / `tools/` / `README.md` に閉じているときだけ**（常駐が読まないと確かめたもの。`config/` / `Gemfile*` / `bin/` / `seed/` は起動時に読む）
- ⚠⚠ **PR をマージしても実機は動かない。**レシピ（chubo2 の `bin/chubo --nodes=bydo --recipes=makoto2`）を当てて初めて置き換わり、⚠ **レシピは常駐を起こし直さない** — `systemctl restart makoto2` が別に要る
- 🔴 **「モンキーテスト待ちで open」の Issue があったら、実機がその版で動いているかを見る**（待っている対象が動いていなければ、何日待っても結果は出ない）
- 🔴 **名前が引けなければ VPN を繋ぐ**（`bydo` / `rubicon` は自宅 LAN の中）。「名前が引けない」は「届かない」ではない
- 🔴 **本番（`rubicon`）の再起動は日曜 08:30〜09:00 を避ける**（キュアスタ！の実況の時間）
- 🔴 **当てるのは [deploy スキル](../deploy/SKILL.md)**（明示呼び出し・同期の中では当てない）
- → 経緯: `docs/CLAUDE.md`「デプロイ・運用」、PR を当てた記録は各リリースの節

## 4. Dependabot

```sh
gh api repos/pooza/makoto2/dependabot/alerts -X GET -f state=open --jq 'length'
```

🔴 **`state=open` で絞る**（絞らないと `fixed` も返り、塞がったアラートを数える）。`bundler-audit` と食い違ったら、まずこれを疑う。

## 5. Codex のレビュー

**最近マージされた PR と、いま open な PR の両方**を、`makoto2` と `makoto-scripts` で見る（⚠ 未返信がいちばん残りやすいのは open PR）。

```sh
gh pr list --state merged --limit 8 --json number --jq '.[].number'
.claude/skills/sync/scripts/codex.sh pooza/makoto2 <PR 番号> ...   # 4 経路・読むだけ
```

- 🔴 **完了の判定はインラインごとの「返信 ＋ 👍」**。①未返信 → 指摘を読んで対応を判断し、返信 ＋ 👍 ②返信済みで 👍 なし → 👍 ③両方済み → 完了
- ⚠⚠ **PR への 👍 は「ある巡が指摘なしで終わった」印**であって、PR 全体が片付いた印ではない。⚠ **巡ごとに見る**（`Reviewed commit:` が巡を指す。後の巡が指摘なしでも、前の巡の指摘は消えない）
- ⚠ **👀（`eyes`）は「読み始めた」の合図で成果物ではない**
- ⚠ **自動のレビューは PR を開いた時と draft を ready にした時しか走らない。**後から積んだコミットを見てほしいときは `@codex review` とコメントする
- 🔴 **P2 は 1 巡だけ。**対応したら再レビューを頼まずに次へ（繰り返すと 10 巡いく）
- ⚠ **`makoto-scripts`（原稿）の PR は Codex を通さず、オーナーのレビューだけでマージする**（2026-09-28）
- → 規約の正本は [`ginseng-style` の docs/workflow.md](https://github.com/pooza/ginseng-style/blob/main/docs/workflow.md)（プラグイン `ginseng:codex-review`）。経緯: `docs/CLAUDE.md`「Codex」の各節

## 6. Sentry

```sh
sentry-cli issues list --project makoto2
```

未解決があれば内容を見て判断し、判断はコメントに残す（→ 報告してから書く）。DSN の置き場の正本は chubo2 の `docs/infra-services.md`。

## 7. chubo2

```sh
git -C ../chubo2 fetch origin && git -C ../chubo2 log HEAD..origin/main --oneline
gh issue list --repo pooza/chubo2 --state open --search makoto
```

- `docs/infra-note.md`（索引）と `docs/infra-servers.md`（MAKOTO の箱）の変更、**MAKOTO に関係する Issue**（実行環境の CT・cure-api の公開・モロヘイヤの webhook 経路）が、makoto2 側の作業の前提になっていないか
- ⚠⚠ **open / `updatedAt` だけで「動いていない」と判断しない。必ずコメントまで読む**（chubo2 も「作業は完了、モンキーテスト待ちで open」を常用する）
- ⚠ **docs と Issue が食い違ったら、Issue のコメントと infra-note を正とする**
- 🔴 **11/1〜11/4 はインフラ作業が凍結される**（chubo2 側の取り決め）

## 8. `ginseng-*`

```sh
for r in ginseng-core ginseng-fediverse ginseng-style; do
  gh issue list --repo "pooza/$r" --state open --search "makoto2 in:body" --json number,title,labels \
    --jq ".[] | \"$r#\(.number) \(.title) [\([.labels[].name] | join(\",\"))]\""
done
grep -A4 'ginseng-' Gemfile.lock | grep -E 'remote|revision|tag'   # ピンの現在地
```

見るのは 4 つ: ①**上流から届いた依頼**（makoto2 の open Issue のうち上流由来のもの・マイルストーンが空のまま放置されていないか）②**こちらから出した依頼の状態**（⚠⚠ `waiting:pr` が付いていたら止まっているのはこちら）③**ピンのずれ**（`Gemfile.lock` の `tag:` が上流の最新からどれだけ離れているか）④**規約の正本が動いていないか**（`ginseng-style` の `docs/workflow.md` / `ruby.md` / `writing.md`。⚠ `.rubocop.yml` は `inherit_gem` なので、上げた日に lint の判定が変わる）。

- 🔴 **`ginseng-*` には専任のエージェントがいる。こちらは催促までで止め、マージしない**
- → 経緯と分担: `docs/CLAUDE.md`「`ginseng-*` との往復」

## 9. cure-api

```sh
gh pr list --repo pooza/cure-api --state open --json number,title,author,mergeStateStatus \
  --jq '.[] | "#\(.number) \(.mergeStateStatus) \(.author.login) \(.title)"'
gh issue list --repo pooza/cure-api --state open
```

- 🔴 **makoto2 は cure-api の最大の消費者なので、cure-api の面倒も makoto2 のセッションで見る。こちらはマージまでやる**（`ginseng-*` と分界が違う）
- 🔴 **とくに「緑のまま眠っている PR」**（`MERGEABLE` / `CLEAN` / `test` 緑・レビュー無しで、押す人がいないだけ）。拾うたびに眠っている
- ⚠⚠ **`CLEAN` は「押せば入る」であって「押してよい」ではない。**マージの前に 5. の 4 経路を当てる（`mergeStateStatus` は Codex を見ない）。⚠ **dependabot の版上げでもメジャー版を跨ぐものは、そのまま入れずに報告する**（2026-11-05 に `ginseng-core` v1 → v4 の #391 を閉じて #339 に集約した）
- 🔴 **dependabot の PR には Codex が付かない**（4 経路とも空のまま）。**必要と判断したら、こちらの基準だけでマージしてよい**（オーナー 2026-11-06）。⚠ 見るのは差分そのもの — 題の版と実際の差分が違うことがある（`tag:` 固定の gem は動かず、題だけ残る・2026-11-06 の #396 は題が `ginseng-core` で中身は facets / sanitize のパッチだけだった）
- ⚠ `UNKNOWN` / `UNSTABLE` は `gh pr checks <n> --repo pooza/cure-api` まで引いて決める（`UNKNOWN` は GitHub がまだ判定していないだけ）
- ⚠ open / `updatedAt` だけで判断せず、コメントまで読む

## 10. マイルストーン

```sh
.claude/skills/sync/scripts/milestones.sh   # 全部の箱の件数・重み（実測）と、docs の表・GitHub の説明文の重み（ずれは ⚠）
```

- 🔴 **docs の表・GitHub の説明文・実測の 3 つを突き合わせる。**⚠⚠ **2 つが一致していることを「正しい」の根拠にしない**（3 つとも別の値だったことがある）
- 🔴 **手で足し引きしない。**重みを書き換える回は、このスクリプトの出力を見てから書く。⚠ 記録に「実測」と書くのは、出力を見た回だけ
- ⚠ **ずれのほとんどは「Issue を足した・動かしたときに表と説明文を直していない」形**（2026-11-05 にも #526 で踏んだ）。🔴 **書く側の手順は [issue スキル](../issue/SKILL.md)**（同期では書かない）
- ⚠ 説明文の重みは「最後に出てくる `重み N` / `重み A → B` の B」を拾う。重みを書いていない箱は `-`（ずれではない）
- ⚠ **閉じた箱も回す**（閉じた Issue も箱の重みに残る）
- → 経緯: `docs/CLAUDE.md`「Issue / マイルストーン運用」

## 11. 曲データの収集（月に 1 回・#294）

`docs/track-corpus.md`「新しいプリキュアソングに追いつく」の「収集の記録」を見て、**前回から 1 か月たっていたら下見を裏で回す**（45 分ほどかかる）。

```sh
python3 seed/itunes_corpus.py --dry-run   # 報告は track_report.md（seed/ は書き換えない）
```

- 🔴 **「新しく見つかった行」が 0 でなければ、反映の PR を作る**（語りのトラックの候補と `kind` は人が見る）
- 🔴 **曲が増えないことを前提にしない**（オーナー）
- ⚠⚠ **回しているあいだに、その作業ツリーでブランチを切り替えない**（収集は `seed/` を書き換える。他の作業は `git worktree` で）

## 12. 誕生日の原稿（#31）

```sh
.claude/skills/sync/scripts/birthday.sh ../makoto-scripts   # 何も出なければ書くものは無い
```

名前が出た人のぶんを 1 本（2〜3 行）書いて `makoto-scripts` に PR を出す（⚠ 原稿の PR はオーナーのレビューだけでマージ）。正本の手順は `makoto-scripts` の README「誕生日の原稿は、使ったら次を書く」。

## 13. pooza/hadlar（ハドラーブロス）

```sh
gh issue list --repo pooza/hadlar --state open --search "makoto2 in:body" --json number,title,labels \
  --jq '.[] | "hadlar#\(.number) \(.title) [\([.labels[].name] | join(","))]"'
gh issue list --state open --search "hadlar in:body"   # 向こうから来た依頼
```

- 2026-11-13 から、ハドラーブロスのチャットボットを pooza/hadlar の専用セッションで並走させている（makoto2 からチャットまわりを写した）。🔴 **情報交換の基本は Issue**（片方で直したら「同じ直しが要るか」を相手のリポジトリに出し、元のコミットか PR を指す）。セッション間のメッセージはその場の質問だけ
- 見るのは 2 つ: ①**こちらから出した依頼の状態** ②**向こうから来た依頼**（makoto2 の open Issue のうち本文が `hadlar` を指すもの・マイルストーンが空のまま放置されていないか）
- 🔴 **hadlar の作業はこちらで肩代わりしない**（答える・依頼するまで）
- → 経緯: `docs/CLAUDE.md`「ハドラーブロス」の段落、pooza/hadlar#1

## 14. 報告とメモリ

- メモリの経過ログ（`project_makoto2-kickoff.md`）に、その日の同期の結果を足す（索引の `MEMORY.md` には積まない）
- 報告は「見たもの」「判断してほしいこと」「その他」に分ける。⚠ **判断を仰ぐものは、問いだけ読んで答えられるように書く**
