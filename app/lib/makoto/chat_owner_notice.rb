module Makoto
  # 悪戯の印が付いたことをオーナーへ DM で知らせる（#510・→ `ChatResponder`）。
  # ⚠ `ChatResponder` から切り出した（v1.0.1 のリリース前レビューで `Metrics/ClassLength` に当たった）。
  # ⚠ `pick` / `service` / `config` / `logger` は取り込む側のもの。
  module ChatOwnerNotice
    OWNER_NOTICE_TYPE = 'chat_owner_notice'.freeze

    # オーナーへの DM に入れる印の言い方。⚠ 真琴の口調の文ではない（原稿の `{reason}` に入る）。
    REASONS = {
      'provoke' => '繰り返し言わせようとした',
      'backstage' => '舞台裏を繰り返し訊いた',
      'impersonate' => '運営を名乗った',
    }.freeze

    private

    # 🔴 **オーナーへ DM で知らせる**（#510）。⚠ モデレーションの判断に足りる材料を載せる。
    #
    # 🔴🔴 **相手をメンションしない**（PR #589 の Codex の P1）。⚠⚠ **DM は本文でメンションした全員に
    # 届く**ので、`@相手` と書くと、オーナーだけへの知らせ（理由・回数・期限）が当の相手にも届く。
    # ⚠ `{acct}` は先頭の `@` を外す（`user@host` は `@` の前が文字なのでメンションにならない）。
    def notify_owner(account, status, penalty, reasons)
      values = {
        acct: account['acct'].to_s.delete_prefix('@'),
        url: status['url'].to_s,
        marks: penalty[:marks].to_s,
        until: penalty[:until_at]&.strftime('%Y-%m-%d %H:%M').to_s,
        reason: reasons.map {|reason| REASONS.fetch(reason)}.join('・'),
      }
      body = pick(OWNER_NOTICE_TYPE)
      unless body
        # ⚠ 原稿が無くても知らせは落とさない（オーナーにだけ届く・口調の文でなくてよい）。
        logger.warn(chat: 'owner', message: 'no script, sending a plain notice')
        body = '{acct} に印が付きました（{reason}・{marks} 回目・{until} まで応答しません）{url}'
      end
      text = "@#{config['/chat/owner']} #{render(body, values)}"
      key = "makoto-chat-owner-#{status['id']}"
      service.post_status(text, visibility: 'direct', idempotency_key: key)
      logger.info(chat: 'owner', acct: account['acct'], reasons: reasons, marks: penalty[:marks])
    end

    def render(body, values)
      return body.gsub(/\{(\w+)\}/) do
        values.fetch(Regexp.last_match(1).to_sym, Regexp.last_match(0))
      end
    end
  end
end
