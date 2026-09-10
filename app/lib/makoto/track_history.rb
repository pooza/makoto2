module Makoto
  # 最近出した曲を避ける（#41）。⚠ **抽選（`TrackLottery`）に「外す」を足すだけ。**
  #
  # ## 🔴 鍵は `dedupe_key`
  #
  # ⚠⚠ **同じ曲が名義違い・盤違いで複数行ある**ので、⚠ **`track.id` で記録すると
  # 同じ曲が別名義で何度も出る**（→ docs/track-corpus.md）。
  #
  # ## ⚠ 外すのは `kind` を選んだ後
  #
  # 🔴 **`TrackLottery` は先に `kind` を重みで選び、その中から一様に引く。**
  # ⚠⚠ **母集合から先に履歴を外すと、小さい `kind` が空になった日だけ重みの分母が
  # 変わる** — **設定した「出る割合」が黙って動く。**⚠ **後から外せば分布は動かない。**
  #
  # ## 🔴 避けきれなくなったら、古いものから解禁する
  #
  # ⚠⚠ **外して 1 曲も残らなければ、その回は履歴を無視する。**⚠ **`nil` を返すと
  # その枠が沈黙する**（→ `SongSource#draw`）ので、**重複を許すほうを採る。**
  #
  # ⚠ **実測では起きない。**🔴 **いちばん小さい `kind` は `instrumental` の 32 曲**で、
  # **既定の窓（300 本・#292）に入るのは出る割合から約 18 曲**（→ config/application.yaml）。
  #
  # ## ⚠⚠ 進行位置ではない
  #
  # 🔴 **「いま何番目の投稿か」をここから復元しない**（→ docs/CLAUDE.md「投稿の欠落は
  # 詰めない。進行位置は状態ではなく計算で出す」）。⚠ **ここが持つのは「何を出したか」
  # だけで、「どこまで進んだか」は持たない。**
  class TrackHistory
    include Package

    attr_reader :post, :size

    # @param post [String] 枠の名前。⚠ **枠ごとに別の履歴として読む**
    # @param size [Integer] 直近この本数を避ける。⚠ **0 なら何もしない**
    # @param repository [TrackHistoryRepository] テストが差し替えるための口
    def initialize(post:, size: 0, repository: nil)
      @post = post.to_s
      @size = size.to_i
      @repository = repository || TrackHistoryRepository.new
    end

    # ⚠ **設定を消せば止まる**（#77）。🔴 **0 のときは読みにも書きにも行かない。**
    def enabled?
      return @size.positive?
    end

    def recent_keys
      return [] unless enabled?
      return canonicalize(@repository.recent_keys(@post, @size))
    end

    # 直近に出した曲を外した母集合。
    #
    # ⚠⚠ **記憶しない**（毎回引き直す）。🔴 **常駐は何日も動き続ける**ので、
    # **覚えると窓が起動時のまま凍る。**
    def exclude(records)
      return records unless enabled?
      keys = recent_keys
      return records if keys.empty?
      fresh = records.exclude(dedupe_key: keys)
      return fresh unless fresh.empty?
      # 🔴 **避けきれなくなった。**⚠ **黙って重複させない** — ⚠⚠ **母集合が
      # 窓より小さいという設定の食い違いなので、気づける場所はここだけ。**
      logger.warn(track: 'history', post: @post, size: @size, message: 'nothing fresh left')
      return records
    end

    # ⚠ **出した曲を覚える。**
    #
    # ⚠⚠ **書けなくても投稿を落とさない**（`PostingJob#record` と同じ判断）。
    # 🔴 **ここは次の抽選のためだけの書き込みで、これに失敗して投稿の側を巻き込むと、
    # 重複回避を足したせいで枠が落ちることになる。**
    def record(track)
      return nil unless enabled?
      return nil unless track
      return @repository.record(@post, track[:dedupe_key])
    rescue => e
      logger.error(track: 'history', post: @post, error: e)
      return nil
    end

    def count
      return @repository.count(@post)
    end

    def last
      return @repository.last(@post)
    end

    def to_s
      return '無し' unless enabled?
      return "直近 #{@size} 本"
    end

    private

    # 🔴 **表記ゆれを寄せた日に、履歴だけが古い鍵で残る**（Codex の P2・#123）。
    #
    # ⚠⚠ **別名表を足して `track import` を流すと、`track.dedupe_key` は代表の鍵に
    # 変わる**が、⚠ **`track_history` に書いてある鍵は書いた日のまま。**
    # 🔴 **`exclude` は文字列で突き合わせる**ので、**寄せた曲だけが窓から外れて、
    # 入れた直後にまた出うる。**
    #
    # ⚠ **行を書き換えるのではなく、読むときに寄せる** — ⚠⚠ **別名表は後から増える**
    # ので、**移行を 1 回走らせる形にすると、次に足した日にまた同じことが起きる。**
    def canonicalize(keys)
      return keys if aliases.empty?
      return keys.map {|key| aliases.key_for(key) || key}.uniq
    end

    # ⚠ **取り込みと同じ表を見る**（→ `TrackImporter.default_aliases`）。
    def aliases
      @aliases ||= TrackImporter.default_aliases
      return @aliases
    end
  end
end
