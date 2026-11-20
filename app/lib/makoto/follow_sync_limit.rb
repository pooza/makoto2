module Makoto
  # 外す数の歯止め（#614・→ `FollowSync`）。
  # ⚠ `FollowSync` から切り出した（v1.2.0 のリリース前レビューで `Metrics/ClassLength` に当たった）。
  # ⚠ `config` / `logger` / `trace` / `report_error` は取り込む側のもの。
  module FollowSyncLimit
    private

    # 🔴 **超えたら 1 人も外さず、知らせる**（#614・2026-11-10 オーナー判断）。⚠⚠ 歯止めは「一覧が欠けて全員を
    # 外す」事故を防ぐためのもの。わざと踏まれると毎回止まるが、外すかは人が決める（`makoto chat follow-sync`）。
    # ⚠ `makoto status` の warning に出し、Sentry は止まり始めた 1 回だけ（毎時鳴らさない）。
    def over_limit(to_unfollow)
      error = Ginseng::GatewayError.new(
        "follow: #{to_unfollow.size} accounts to unfollow is over the limit (#{unfollow_limit})",
      )
      logger.error(follow: 'sync', message: error.message)
      first = Heartbeat.follow_over_limit.nil?
      trace(:record_follow_over_limit, to_unfollow.size, unfollow_limit)
      report_error(error, follow: 'sync') if first
      return Set.new
    end

    def unfollow_limit
      return config['/chat/follow/unfollow_limit'].to_i
    end
  end
end
