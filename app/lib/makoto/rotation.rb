module Makoto
  # 用意した原稿を通し番号で順に送る規則（#223）。**朝挨拶（#17）と曲紹介（#16）が
  # 同じものを使う。**
  #
  # ⚠⚠ **同じ規則を 2 箇所に書かない**（`OwnCredit` / `ProcessIdentity` と同じ動機）。
  # 🔴 **食い違うと「片方だけ周期で同じ順番が戻る」**という、**目視でしか気づけない
  # 壊れ方**になる（→ #183 の「規則が 3 箇所で揃いきっていない」）。
  #
  # ## 🔴 素の順送りは周期で同じ順番になる（#223）
  #
  # ⚠ **通し番号 % 本数**だけだと、⚠⚠ **本数ぶん進むたびにまったく同じ順番が戻る。**
  # 🔴 **オーナーの判断（2026-09-01）: それはイヤ。**
  #
  # - 🔴 **前半・後半を保ったまま、その中を毎周組み替える。**⚠⚠ **完全に組み替えると、
  #   周の境目で最短 2 つまで落ちる**（前周の最後と次周の最初）。⚠ **半分に留めると、
  #   同じ原稿が戻るのは最短でも本数の半分**
  # - 🔴 **並べ替えの鍵はハッシュ**（`SHA256("周回番号-鍵")`）。⚠⚠ **`Array#shuffle` は
  #   Ruby の実装・版に依存しうる** — **下見と実機がずれる余地を作らない**
  # - ⚠ **状態は持たない**（通し番号は日付と枠から出る → docs/CLAUDE.md「進行位置は
  #   状態ではなく計算で出す」）
  #
  # ⚠ **通し番号の作り方は呼ぶ側が決める。**🔴 **1 日 1 本の枠はユリウス通日そのもの**
  # （#17）、⚠⚠ **1 日に複数本ある枠は「通日 × 本数 ＋ 枠の番号」**（#16）。
  module Rotation
    module_function

    # 通し番号から 1 本引く。⚠ **空なら nil。**
    def pick(records, serial)
      return nil if records.empty?
      return records.first if records.size == 1
      cycle = serial / records.size
      return cycle_order(records, cycle)[serial % records.size]
    end

    # その周の並び。⚠ **前半どうし・後半どうしの中だけで組み替える。**
    def cycle_order(records, cycle)
      half = records.size / 2
      return shuffle(records[0, half], cycle) + shuffle(records[half..], cycle)
    end

    # 🔴 **決定的に組み替える。**⚠⚠ **`Array#shuffle(random:)` は Ruby の実装・版に
    # 依存しうる**ので使わない（**下見と実機がずれる余地を作らない**）。
    def shuffle(records, seed)
      return records.sort_by {|record| Digest::SHA256.hexdigest("#{seed}-#{key_of(record)}")}
    end

    # 🔴 **箱をまたいで同じ値になる鍵**（#223・Codex の P2）。⚠⚠ **`id` は DB ごとの
    # 採番**なので、**`bydo` と `rubicon` で同じ原稿が別の番号になる** — ⚠ **`id` で
    # 並べると、ステージングの下見が本番の並びを言い当てられない。**
    # ⚠ **`slug` はファイル（`makoto-scripts`）が持つ鍵なので、どの箱でも同じ**（#224）。
    def key_of(record)
      return record[:slug] if record[:slug]
      # ⚠ **移送前の行はまだ `slug` を持たない**（→ #224）。⚠⚠ **その箱の中では
      # 決定的**だが、**箱をまたいでは揃わない。**
      return "id:#{record[:id]}"
    end
  end
end
