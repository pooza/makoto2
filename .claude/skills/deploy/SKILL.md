---
name: deploy
description: makoto2 を実機（bydo / rubicon）に当てる。時刻の門 → chubo2 のレシピ → config:lint と drop-in の確認 → restart → 登録ログ 7 行・監視の口 3 本の確認。ユーザーが「デプロイしましょう」「bydo に当てて」などと明示したときだけ使う。
disable-model-invocation: true
---

# 実機に当てる（デプロイ）

⚠ **この手順の正本はこのファイル**（#536 で `docs/CLAUDE.md`「通常リリース手順」9. と同期 3. の「実機に当てる」から移した）。
**「なぜそうするか」と踏んだ記録は `docs/CLAUDE.md`「デプロイ・運用」と各リリースの節に残してある。**手順を足すときはここだけを直す。
🔴 **実機を動かす手順なので明示呼び出しに限ってある。**各段はユーザーの指示を確かめてから進める。

| ホスト | 追うブランチ | 投稿先 |
| --- | --- | --- |
| `bydo` | `develop` | `st2.precure.ml`（ステージング） |
| `rubicon` | `main` | 🔴 `precure.ml`（本番）。**タグを打った版だけを出す**（[release スキル](../release/SKILL.md) 8. の後） |

## 1. 何が変わるかを見る

```sh
.claude/skills/sync/scripts/hosts.sh <ホスト>   # 動いているもの ＝ 置いてあるもの か
git log <動いている revision>..origin/<ブランチ> --name-only
```

- ⚠ **差分が `docs/` / `tools/` / `README.md` に閉じていれば再起動は要らない**（常駐が読まない）。`config/` / `Gemfile*` / `bin/` / `seed/` は起動時に読む
- 🔴 **行を消す変更（原稿の type を落とす・正本を移す）を含む版では、3. で `corpus import` を叩く**（レシピは流さない）

## 2. 時刻の門

```sh
.claude/skills/deploy/scripts/gate.sh <ホスト> [分]   # 読むだけ。分は作業の見込み（既定 15）
```

- 🔴 **レシピと `restart` の間に、自分から出す枠の頭（＋ tolerance 30 秒）を入れない。**枠の頭は設定から毎回引く（数字を手順に焼かない・#279）
- 🔴 **`rubicon` は実況の時間（設定 `/commentary/windows` の強い窓・いまは日曜 08:30〜09:00）を避ける。**門はホストの設定から窓を引く（直書きしない・#561）。11/1〜11/4 はインフラの凍結（門が止める）
- ⚠ リリースの文面が枠を約束しているとき（「明日の朝から」など）は門がもう 1 つ増える → `docs/CLAUDE.md`「`0.5` 限りの手順」の記録

## 3. レシピを当てる

```sh
cd ~/repos/chubo2 && bin/chubo --nodes=<ホスト> --recipes=makoto2
```

- ⚠ **レシピは常駐を起こし直さない**（`enable` するだけ）。⚠⚠ **レシピのあとは間を空けずに restart する** — 常駐は Zeitwerk の遅延読み込み（`eager_load` していない）なので、**古い常駐がまだ読んでいない定数を、置き換わった新しいファイルから読みうる**（新旧が混ざった常駐になる・#561）。`track import` と台本の `message import --prune` は流れる
- 🔴 **行を消す変更を含む版だけ、ここで `corpus import`**（「更新」と「起動」の間。起きたあとに叩くと、併存したままの母集合から 1 本引きうる）:

  ```sh
  ssh <ホスト> 'sudo -u deploy -i bash -c "cd ~/repos/makoto2 && bin/makoto corpus import"'
  ```

- 設定と drop-in を見る（🔴 **drop-in が残っていたら `restart` しない** — 騙した時刻で 162 投稿が始まる・#174）:

  ```sh
  ssh <ホスト> 'sudo -u deploy -i bash -c "cd ~/repos/makoto2 && bundle exec rake config:lint"'
  ssh <ホスト> 'systemctl show makoto2 -p DropInPaths'
  ```

## 4. 起こし直して確かめる

```sh
ssh <ホスト> sudo systemctl restart makoto2
.claude/skills/deploy/scripts/verify.sh <ホスト>   # 読むだけ
```

- 見るもの: `revision` が置いたもの・`jobs` 7 本・🔴 **登録ログに枠の名前 7 行**（`announcement` / `morning` / `song` / `live-eve` / `live-open` / `live` / `live-close`）・heartbeat の `version`・drop-in なし・`/healthz` の 3 口が 200
- ⚠ `jobs` の本数だけでは古い常駐が残っていても通る。名前が出るのは登録ログだけ
- 🔴 **本番ではもう 1 つ、下見を回す**（ステージングの下見は本番の答えではない・#144）:

  ```sh
  ssh rubicon 'sudo -u deploy -i bash -c "cd ~/repos/makoto2 && bin/makoto live setlist --date=<次の 11/4> --mc"' | tail -5
  ```

  ⚠ `bydo` と差が出ること自体は異常ではない（版の違いで説明が付けば正常）。説明が付かない差だけを報告する

## 5. 記録

- 本番に当てたら chubo2 の `docs/infra-history.md` に 1 行（chubo2 の docs は main へ直接・PR を立てない）
- リリースの一部なら、結果は [release スキル](../release/SKILL.md) 11. の節へ
