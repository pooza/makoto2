module Makoto
  # ライブ 8 時間の枠に載せる中身（#13）。`PostingJob` の `source` として渡す。
  #
  # ⚠ **枠の番号を `Setlist` に渡して 1 項目を取り、本文にするだけ。**「いま何曲目か」を
  # 覚えないので、⚠ **落ちて戻ってきても曲順がずれない**（→ `Timetable#index_at`）。
  #
  # ⚠⚠ **MC は乱択で引かない。**`MessageSelector#list` で id 順に並べ、**何本目の MC か
  # で決める。**枠ごとに引き直すと、同じ原稿が何度も出て出ない原稿が残る。
  class LiveProgram
    include Package

    # @param gate [MessageSelector] ライブ当日かを判定する口（開始告知の記念日登録）
    def initialize(timetable:, mc_selector:, gate:, repository: nil, cure_api: nil)
      @timetable = timetable
      @mc_selector = mc_selector
      @gate = gate
      @repository = repository
      @cure_api = cure_api
    end

    # カバーに添える断り。⚠ 設定から直に読む（呼び出し側に横流しさせない）。
    def cover_prefix
      return config['/live/setlist/cover_prefix']
    end

    # 枠の頭の時刻 → 投稿の本文。⚠ **枠の外・ライブ当日でない・並びの外・原稿が
    # 無ければ nil**（`PostingJob` が「投稿しない」と解釈する）。
    def call(time = nil)
      time ||= Time.now
      entry = setlist(time)&.at(@timetable.index_at(time))
      return nil unless entry
      return mc_text(entry, time) if entry.mc?
      return TrackPresenter.new(entry.track, prefix: (cover_prefix if entry.cover?)).to_s
    end

    # ⚠⚠ **ライブ当日か。**告知や MC は「その日の原稿が無ければ出ない」で黙るが、
    # ⚠ **曲は原稿ではないので黙らせるものが無い。**これが無いと、毎日 12:02〜20:00 に
    # 8 時間ぶんの曲が流れる。⚠ **日付の正本は `/message/anniversary`**（開始告知の
    # type が登録されている日＝ライブの日）なので、ここでも設定を 2 箇所に割らない。
    def live_day?(time = nil)
      return @gate.anniversary_types_on(date_of(time || Time.now)).any?
    end

    # その日の並び。⚠ **日付ごとに 1 つだけ組んで使い回す**（枠ごとに組み直すと
    # 8 時間で 160 回 DB を舐める）。
    def setlist(time = nil)
      time ||= Time.now
      return nil unless @timetable.cover?(time)
      return nil unless live_day?(time)
      date = date_of(time)
      @setlists ||= {}
      @setlists[date] ||= Setlist.new(
        date: date, slots: @timetable.size(date), repository: @repository, cure_api: @cure_api,
      )
      return @setlists[date]
    end

    private

    # ⚠ **原稿が尽きたら頭に戻る。**用意した本数より MC の枠が多くても、無言の枠を
    # 作らない。⚠ 1 本も無ければ nil（＝その枠は投稿しない）。
    def mc_text(entry, time)
      scripts = @mc_selector.list(time)
      return nil if scripts.empty?
      return scripts[entry.ordinal % scripts.size][:body]
    end

    # ⚠ ホストの TZ ではなく `/scheduler/timezone`（→ `Timetable` と同じ正本）。
    def date_of(time)
      return @timetable.timezone.utc_to_local(time.getutc).to_date
    end
  end
end
