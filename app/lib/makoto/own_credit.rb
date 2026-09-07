module Makoto
  # 「その名義は本人か」の規則（#121 / #155 / #164 / **#177**）。
  #
  # ⚠⚠ **同じ規則を 3 箇所で使う**ので切り出した（`ProcessIdentity` と同じ動機）—
  # **表示**（`LiveProgram#show_artist?` ＝ 名義を隠すか）、**本編**（`Setlist#songs`
  # ＝ 本人の曲として歌うか）、**カバー母集合**（`CoverSelector#pool_of_singers`
  # ＝ 「お借りした歌」に混ぜないか）。🔴 **判定が箇所ごとに食い違うと、
  # 「本人の曲なのに借り物として出す」形が出る**（#177 で実際に出た）。
  #
  # ## ⚠ ユニット名義（#177）
  #
  # 🔴 **本人がメンバーのユニットは、名前が書いていなくても本人の曲**（2026-08-23・
  # オーナー）。⚠⚠ **`キュア・カルテット` は名義の文字列に `宮本佳那子` を含まない**
  # ので、⚠ **`own_artists` だけでは拾えない**（母集合 323 曲を当てて 1 曲しか出な
  # かった。拾えた 1 曲は括弧の中にメンバーが書いてあっただけ）。
  #
  # ⚠⚠ **ユニット名とメンバーの対応は名義の文字列の中に無い** — **区切り文字を
  # どう割っても出てこない情報**なので、**設定に置くしかない**（→ #157 の辞書照合）。
  #
  # ## ⚠ 中黒に依存しない
  #
  # ⚠⚠ **`キュア・カルテット` と `キュアカルテット` を同じものとして照合する。**
  # ⚠ **実データは 14 曲すべて中黒あり**（2026-08-23 実測）だが、**名義の表記は
  # 供給元しだい**なので、**中黒が落ちた表記が来た日に黙って外れる形にしない。**
  #
  # 🔴 **これは「名義を割る」話ではない**（#155 で外したあの規則には戻らない）—
  # **落としてから含むかを見るだけ**で、⚠ **自分の名義にも各ユニット名にも
  # 中黒以外の区切りは要らない。**
  module OwnCredit
    # ⚠ 照合の前に落とす区切り。⚠⚠ **中黒だけ**（全角・半角・ラテンの中点）。
    SEPARATORS = /[・･·]/

    # 🔴 **コーラスは本人の判定に使わない**（2026-08-23・オーナー・#177）。
    #
    # ⚠⚠ **コーラスで参加していても、その曲は本人の曲ではない** — 実例:
    # **`ぷりきゅあ5 plus くるみ[CV:仙台エリ]/コーラス:キュア・カルテット`**
    # （主名義は別、キュア・カルテットはコーラス）。⚠ **これを本人の曲にすると、
    # 「歌っていない曲を持ち歌として歌う」形になる。**
    #
    # ⚠⚠ **落とすのはコーラスの区画だけ**（`宮本佳那子/コーラス:ヤング・フレッシュ`
    # は**本人が主名義**なので残る）。⚠ **区画の終わりは名義の区切り**（`/`）**と
    # 括弧の閉じ**で、🔴 **`、` や中黒では切らない** — **コーラスの人名を並べる
    # 区切りなので、そこで切ると 2 人目以降が区画の外に残る。**
    CHORUS = %r{コーラス[:：][^/)\]】]*}

    module_function

    # その名義に本人が含まれるか。
    #
    # ⚠ **設定が空なら常に false**（消せば元の挙動に戻る → #77）。
    def own?(value)
      names = credits
      return false if names.empty?
      text = normalize(value)
      return false if text.blank?
      return text.match?(Regexp.union(names))
    end

    # 本人の曲になりうる行（#177）。⚠ **`live` フラグの曲 ＋ ユニット名義の曲。**
    #
    # 🔴 **`live` は「収集で本人の曲として集まったもの」**（`seed/makoto_tracks_live.json`）
    # なので、⚠⚠ **ユニット名義で出ている曲は入っていない** — **`ガンバランス de
    # ダンス～希望のリレー～ / キュア・カルテット` が、本人が参加している曲なのに
    # カバー母集合に居た。**
    #
    # ⚠ **`live` フラグ（seed）は書き換えない**（#63 / #118 と同じ — **並びの都合は
    # 選曲が持ち、データの区分は触らない**）。
    #
    # 🔴 **判定は `own?` ひとつ**（#183・2026-09-07）。⚠⚠ **かつては SQL の `LIKE` で
    # 粗く絞ってから `own?` で確かめる 2 段だった**が、⚠ **`LIKE` に並べていたのは
    # 「設定の綴り」と「中黒を落とした綴り」の 2 つだけ**で、🔴 **`own?` の正規化
    # （NFKC ＋ 空白除去 ＋ コーラス区画除去 ＋ 中黒除去）とは寄る幅が違った。**
    #
    # ⚠⚠ **`キュア･カルテット`（半角中黒）は `own?` が真で `LIKE` が偽** — ⚠ **本編は
    # ここで落ち、カバー母集合は `own?` で弾くので、どちらにも出ない**（**消えたことに
    # 気付ける場所が 1 つも無い**）。
    #
    # ⚠ **4,305 行を Ruby で判定する。**🔴 **SQL では `own?` と同じ正規化ができない**
    # 以上、**規則を 2 つ持つより全件を見るほうが安い**（実測で差は出ない）。
    #
    # ⚠⚠ **今日は 1 行も結果が変わらない**（実測 2026-09-07・**`own?` が真で `live`
    # でない vocal 9 行はすべてユニット名義**）。🔴 **変わるのは `own_artists` 名義の
    # 非 `live` 行が来た日**で、⚠ **そのとき本編に入るのは #177 の規則どおり**
    # （**`Setlist#songs` の 2 段目が元からそう書いてあった**）。
    def records(repository)
      return repository.live if credits.empty?
      ids = own_ids(repository)
      return repository.live if ids.empty?
      return repository.dataset.where(Sequel.|({live: true}, {id: ids}))
    end

    # ⚠ **`live` でない行のうち、名義が本人のものの id。**
    def own_ids(repository)
      return repository.dataset.exclude(live: true).select_map([:id, :artist_name])
          .select {|_, name| own?(name)}.map(&:first)
    end

    # 🔴 **本人の曲の `dedupe_key`**（#183）。⚠⚠ **カバー母集合が「代表を選ぶ前に」
    # 外すために使う** — ⚠ **選ばれた代表 1 行だけを `own?` に掛けると、同じ曲に
    # 他人名義の行が混ざっていたときに、そちらが代表になって残る。**
    #
    # ⚠ **`dedupe_key` が NULL の行は入れない**（🔴 **`NOT IN` は NULL が 1 つでも
    # 混ざると 1 行も返さない** — **静かに「カバー無し」になる**）。
    def keys(repository)
      return records(repository).exclude(dedupe_key: nil).select(:dedupe_key)
    end

    # 突き合わせる名義（自分の名義 ＋ 本人がメンバーのユニット）。
    #
    # ⚠ **設定を 2 つに分けてある** — **`own_artists` は本人そのもの**、
    # ⚠⚠ **`own_units` は「本人が入っている」という外の知識**で、**根拠が違う。**
    def credits
      names = Array(optional_config('/live/setlist/own_artists')) +
        Array(optional_config('/live/setlist/own_units'))
      return names.map {|name| normalize(name)}.compact_blank
    end

    # ⚠ **NFKC ＋ 空白除去**（`宮本 佳那子` と `宮本佳那子` を寄せる）**＋ 中黒除去。**
    def normalize(value)
      return CureApiService.normalize(value).gsub(CHORUS, '').gsub(SEPARATORS, '')
    end

    # ⚠⚠ **`rescue` で拾わない**（→ docs/CLAUDE.md「fail-open な `rescue` の内側で
    # 設定値を読まない」）。⚠ **キーの有無だけを見る** — **値を読む側の失敗を
    # 握り潰すと、設定パスの typo が「名義を隠さない」に化ける。**
    def optional_config(key)
      config = Config.instance
      return nil unless config.key?(key)
      return config[key]
    end
  end
end
