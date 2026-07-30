# 曲データの収集（iTunes Search API）

旧 DB の `track` テーブルは 0 件で、**旧実装では曲の登録が手作業だった**。iTunes からの自動取得はここを直接解消する。2026-07-29 に実収集して成立を確認済み。

## iTunes Search API で成立する

**認証不要**。`https://itunes.apple.com/search` / `https://itunes.apple.com/lookup`（`country=jp`）を使う。

- アーティスト検索 → `entity=song` 列挙。**1 クエリ 200 件で頭打ち**になるので、`entity=album` からアルバム単位でも引いて補う
- 取れるフィールド: `trackName` / `collectionName` / `artistName` / `releaseDate` / `trackTimeMillis` / `trackNumber` / `discNumber` / `primaryGenreName` / `trackViewUrl` / `previewUrl` / `artworkUrl100` / `trackId` / `collectionId`
- **`trackId` が自然キー**になる
- リクエスト間隔は 2 秒

代替案: Spotify（要認証。モロヘイヤに連携実績があるが、クォータ規約の都合で塩漬け中）、MusicBrainz（認証不要・正準 ID 向き）。**まずは iTunes で足りる。**

なおモロヘイヤに `itunes_url` ハンドラがあるので、この API はエコシステム内で既知。

## 曲は 2 集合に分ける

| 集合 | 定義 | 用途 |
| --- | --- | --- |
| **ライブ用** | `宮本佳那子` / `剣崎真琴` / `キュアソード` の和集合 | 11/4 バースデーライブ |
| **普段用** | ライブ用 ＋ **プリキュアソング**（`artistName` か `collectionName` に「プリキュア」を含む） | 日常の曲紹介 |

## 収集の要点

- **`term=プリキュア` 単体では artist / album / song いずれも 200 件で切れる。** [pooza/rubicure](https://github.com/pooza/rubicure) の `config/series.yml` にあるシリーズ名 22 件を種にしてアルバムを集め、**アルバム単位で曲を引く**のが有効
- ⚠ **アルバム経由だと他アーティストが混入する**（主題歌シングルやサントラを丸ごと拾うため。実測で `林ゆうき` 41 曲・`寺田志保` 38 曲など劇伴が 121 曲）。**`artistName` に対象語のいずれかを含むものだけ残すフィルタが必要**
- ⚠ **ライブ用はシリーズ名の種だけでは 126 曲しか取れない。** 宮本佳那子本人のアルバム（21 枚）を artist 経由で列挙して合流させて 234 曲になる。**2 系統の収集を合わせる必要がある**
- ⚠ **artist 経由でアルバムを全部辿ると 4,556 枚に膨らむ**（167 アーティスト × 各 200 枚）。API を叩きすぎるうえ重複が大半なので、シリーズ系は 876 枚に留めるのが妥当

## 収集結果（2026-07-29・アルバム 876 枚から 12,204 曲を取得して分類）

| 集合 | 曲数 | 曲名ユニーク | vocal | bgm | karaoke | tv_size | instrumental |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **ライブ用** | **234** | 182 | **194 (82%)** | 11 | 19 | 10 | 0 |
| **普段用** | **4,305** | 3,702 | 1,479 (34%) | **2,298 (53%)** | 335 | 161 | 32 |

## 抽選は重み付けする

`kind`（`vocal` / `bgm` / `karaoke` / `tv_size` / `instrumental`）で分類し、**抽選を重み付けする**。

- ⚠ **普段用は BGM が過半（53%）。一様抽選すると曲紹介がサントラだらけになる**＝重み付けは必須
- ライブ用は逆に vocal が 82% で素直。8 時間のライブに対し vocal 194 曲＝**重複なしで回せる量**
- **サントラは捨てない。** 曲名に色気が無いぶん `previewUrl` と `artworkUrl` で補い、`bgm` は紹介文テンプレートを変えて**アルバム／シリーズを主役にする**

## [seed/](../seed/) の中身

2026-07-29 の収集物。**セッションのスクラッチパッド（`/tmp` 配下）にあって消えかけたので退避した**もので、置き場所は暫定。正式なデータ層が決まったら移動・削除してよい。

| ファイル | 中身 |
| --- | --- |
| `makoto_tracks_live.json` | ライブ用 234 曲 |
| `makoto_tracks_daily.json` | 普段用 4,305 曲 |
| `itunes_union.py` | artist 系の収集（宮本佳那子 / 剣崎真琴 / キュアソード） |
| `itunes_corpus.py` | シリーズ系の収集（rubicure のシリーズ名を種にアルバム経由） |

JSON は `trackId` をキーに持つオブジェクトの配列で、フィールドは `artistName` / `artworkUrl100` / `collectionId` / `collectionName` / `kind` / `previewUrl` / `releaseDate` / `trackId` / `trackName` / `trackNumber` / `trackTimeMillis` / `trackViewUrl`。`kind` はスクリプトが付けた分類で、iTunes 由来のフィールドではない。
