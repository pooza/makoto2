module Makoto
  # MAKOTO のフォロワーの一覧を手元に持つ（#510 の門）。
  #
  # ## 🔴 トークンを作り直さないための形（2026-11-07・オーナー判断）
  #
  # ⚠⚠ **相手ごとに「フォロワーか」を聞く API（`relationships`）は `read:follows` が要り、いまの
  # トークンでは 403。**スコープは発行後に足せないので、**`read:accounts` で引ける自分のフォロワー一覧を
  # 持つ**（→ `MastodonService#follower_ids`）。
  #
  # - 🔴 **新しいフォローは、受信の口（#29）に届くフォローの通知ですぐ足す**（→ `MentionListener`）。
  #   ⚠ **フォローしてすぐ話しかけてくれた人を待たせない**
  # - ⚠ **フォローを外したことは通知されない**ので、`/chat/followers/refresh` ごとに全部引き直して拾う。
  #   ⚠ **外した直後の間だけは返事をしうる**（実害は小さい・オーナー了承）
  # - 🔴 **一度も引けていなければ例外**（呼び出し側が黙る）。⚠⚠ **空の一覧で「フォロワーでない」と
  #   答えると、フォロワー全員へ「フォローしてくれたら」を返してしまう。**⚠ 引き直しに失敗したときは、
  #   前の一覧を使い続ける（ログに残す）
  class FollowerRoster
    include Package

    # @param fetcher [#call] `-> Array<String>`。⚠ テストが差し替える
    # @param clock [#call] `-> Time`。⚠ テストが差し替える
    # @param record [Boolean] 痕跡に書くか。⚠⚠ **常駐の一覧だけが書く**（#640）— CLI（別のプロセス）の一覧は
    #   未取得から始まるので、失敗で常駐に偽の warning を立て、成功で常駐の本当の warning を消していた
    def initialize(fetcher: nil, clock: nil, record: true)
      @record = record
      @fetcher = fetcher || -> {MastodonService.new.follower_ids}
      @clock = clock || -> {Time.now}
      @ids = nil
      @loaded_at = nil
      @mutex = Mutex.new
      @refreshing = Mutex.new
    end

    def self.instance
      @instance ||= new
      return @instance
    end

    def include?(account_id)
      refresh if stale?
      ids = @mutex.synchronize {@ids}
      raise Ginseng::GatewayError, 'followers: not loaded yet' unless ids
      return ids.include?(account_id.to_s)
    end

    # フォローの通知を受けた。⚠ **まだ一度も引けていなければ何もしない**（引けたときに入っている）。
    #
    # 🔴 **引き直しの最中に足したぶんも残す**（v1.0.0 のリリース前レビュー）。⚠⚠ 引き直しは引き終えた一覧で
    # 丸ごと差し替えるので、引いている数秒のうちに来たフォローが消え、フォローしたばかりの人に
    # 「フォローしてね」を返していた。
    def add(account_id)
      @mutex.synchronize do
        @ids&.add(account_id.to_s)
        @fetching&.add(account_id.to_s)
      end
    end

    def size
      return @mutex.synchronize {@ids&.size}
    end

    # 手元の一覧の写し（#606）。⚠ **まだ一度も引けていなければ nil。**
    def ids
      return @mutex.synchronize {@ids&.dup}
    end

    # ⚠ **引き直しは 1 本ずつ**（PR #618 の Codex の P2）。⚠⚠ 返事のスレッド（`include?`）と突き合わせのスレッド
    # （`FollowSync#sync`）が重なると、引き直しの最中に足したぶん（`@fetching`）を互いに上書き・消去する。
    # ⚠ 一覧を引く間は `@mutex` を掴まない（`include?` / `add` を待たせない）。
    def refresh
      return @refreshing.synchronize {refresh_once}
    end

    def stale?
      loaded_at = @mutex.synchronize {@loaded_at}
      return true unless loaded_at
      return @clock.call - loaded_at >= interval
    end

    private

    def refresh_once
      @mutex.synchronize {@fetching = Set.new}
      ids = @fetcher.call.to_set(&:to_s)
      @mutex.synchronize do
        @ids = ids | @fetching
        @fetching = nil
        @loaded_at = @clock.call
      end
      logger.info(chat: 'followers', count: ids.size)
      trace(:clear_followers_unloaded)
      return ids.size
    rescue => e
      # ⚠ 前の一覧があれば使い続ける。⚠⚠ **無ければ `include?` が例外にする**（→ クラスの冒頭）。
      logger.warn(chat: 'followers', message: 'could not refresh', error_class: e.class.name,
        error: e)
      loaded = @mutex.synchronize do
        @fetching = nil
        @loaded_at = @clock.call if @ids
        !@ids.nil?
      end
      # 🔴 **一度も引けていなければ痕跡に残す**（#611 → `makoto status`）。
      trace(:record_followers_unloaded) unless loaded
      return nil
    end

    # ⚠ **痕跡が書けなくても一覧は止めない**（観測のためのもの）。
    def trace(method)
      return unless @record
      Heartbeat.public_send(method)
    rescue => e
      logger.error(chat: 'followers', error: e)
    end

    def interval
      seconds = Fugit::Duration.parse(config['/chat/followers/refresh'].to_s)&.to_sec
      unless seconds&.positive?
        raise Ginseng::ConfigError,
          "chat: bad followers refresh '#{config['/chat/followers/refresh']}'"
      end
      return seconds
    end
  end
end
