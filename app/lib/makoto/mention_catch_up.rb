module Makoto
  # 繋ぎ直したとき（と起動時）に、取りこぼしたメンションに追いつく（#610）。
  #
  # ## 🔴 追いつく・古いものは捨てる（2026-11-10・オーナー判断）
  #
  # ⚠⚠ Mastodon の Streaming は、繋ぎ直しても切れていた間の通知を送り直さない。デプロイ・再起動・繋ぎ直しの
  # 待ち（最長 `/streaming/retry/max`）の間のメンションに、二度と返事をしなかった。⚠ 止めるときに返事の
  # 待ち行列に残っていた通知も同じ。
  #
  # - 🔴 **最後に処理し終えた通知の ID**（`Heartbeat.notification_id`・`ChatResponder` が書く）から、通知 API で
  #   メンションを引き、古い順に返事の待ち行列へ積む。⚠ 一度も処理していなければ何もしない（初回）
  # - 🔴 **来てから `/chat/catch_up/max_age`（15 分）を超えたものには返さない**（#599 の実況の窓の締め切りと
  #   同じ考え方 — 遅れて着いた返事は流れに合わない）。⚠ 受けた時刻は投稿の時刻にする（窓の中の締め切りも効く）
  # - ⚠ **二重に返さない**: 繋ぎ直しで同じ通知がストリームにも来たら、`ChatResponder#seen?` が畳む。再起動を
  #   またいだ分は、返事の冪等キー（`makoto-chat-<status id>`）が畳む
  # - 🔴 **引けなかったら、引けるまで起点を止める**（PR #633 の Codex の P2）。⚠⚠ 止めないと、その間にライブで
  #   届いた通知で起点が進み、取りこぼした分が起点より前になって二度と引けない（→ `Heartbeat.hold_notification_id`）。
  #   ⚠ 受信の口は、次に何か届いたときにもう一度呼ぶ（間隔は `RETRY_INTERVAL` 以上 → `MentionListener`）
  # - ⚠ **例外を上げない**（受信を止めない）
  # - 🔴 **積んだ分を処理し終えるまで、起点はそれを越えない**（#637 → `Heartbeat.checkpoint_notification`）。
  #   ⚠ 起点を止めている間に処理し終えた分は除く（#635）
  class MentionCatchUp
    include Package

    # 1 回に引く上限。⚠ 15 分ぶんには十分（全体の上限は 1 日 150 回）。
    # 🔴 **返事の待ち行列の半分まで**（#637）。⚠⚠ 埋めると、その間に届いたライブのメンションが落ちる。
    LIMIT = ChatResponder::QUEUE_MAX / 2

    # @param handler [#call] `(notification, received_at)` で積む（`ChatResponder`）
    # @param service [MastodonService] ⚠ テストが差し替える
    # @param clock [#call] `-> Time`。⚠ テストが差し替える
    def initialize(handler:, service: nil, clock: nil)
      @handler = handler
      @service = service
      @clock = clock || -> {Time.now}
    end

    # @return [Integer, nil, false] 積んだ数。⚠ 追いつく起点が無ければ nil、引けなかったら false（もう一度呼ぶ）
    #
    # ⚠ **設定は rescue の外で読む**（v1.0.1 のリリース前レビュー）— 内側で読むと、設定の誤りが「引けなかった」に
    # 化けて起点を止め続ける。
    def call
      since = Heartbeat.notification_id
      return nil unless since
      return fetch(since, max_age)
    end

    private

    def fetch(since, age)
      notifications = service.mentions_since(since, limit: LIMIT)
      queued = notifications.count {|notification| feed(notification, age)}
      Heartbeat.release_notification_id
      logger.info(stream: 'catch_up', since:, found: notifications.size, queued:)
      return queued
    rescue => e
      logger.warn(stream: 'catch_up', message: 'could not catch up', error_class: e.class.name,
        error: e)
      hold(e)
      return false
    end

    # 🔴 **止まり始めた 1 回だけ Sentry へ**（v1.0.1 のリリース前レビュー）。⚠ 続いていることは `makoto status` の
    # warning が言う（→ `Health#chat_trace_warnings`）。
    def hold(error)
      first = Heartbeat.catch_up_pending_since.nil?
      Heartbeat.hold_notification_id
      report_error(error, stream: 'catch_up') if first
    rescue => e
      logger.error(stream: 'catch_up', error: e)
    end

    # @return [Boolean] 積めたか（#637 — 待ち行列が溢れて落ちたぶんは数えない）
    def feed(notification, age)
      # 🔴 **起点を止めている間に処理し終えたものは除く**（#635 → `Heartbeat.handled_notification?`）。
      if Heartbeat.handled_notification?(notification['id'])
        logger.info(stream: 'catch_up', result: 'handled', notification_id: notification['id'])
        return false
      end
      created_at = Time.parse(notification['created_at'].to_s)
      if @clock.call - created_at > age
        logger.info(stream: 'catch_up', result: 'stale', notification_id: notification['id'])
        return false
      end
      return @handler.call(notification, created_at) == true
    rescue ArgumentError
      return false
    end

    def max_age
      value = config['/chat/catch_up/max_age']
      seconds = Fugit::Duration.parse(value.to_s)&.to_sec
      return seconds if seconds&.positive?
      raise Ginseng::ConfigError, "chat: bad catch_up max_age '#{value}'"
    end

    def service
      @service ||= MastodonService.new
      return @service
    end
  end
end
