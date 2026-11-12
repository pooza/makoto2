module Makoto
  # チャットボットに渡す「いま」と「最近の自分の投稿」（#624 / #652）。→ `ChatModel#system_blocks_for`
  #
  # ## 🔴 キャッシュの印より後ろに置く
  #
  # 指示書＋台帳（約 9.4k トークン）は誰へも同じなのでキャッシュしている。ここは毎回変わる（時刻）・日に何度も
  # 変わる（投稿）ので、⚠⚠ **その前に置くとキャッシュが毎回外れる。**最後の塊として、印を付けずに足す。
  # ⚠ そのぶんは毎回ふつうの単価で読まれる（数百トークン・1 応答 約 $0.001〜0.003 増える）。
  #
  # ## 渡すもの
  #
  # - いまの日時（曜日つき）。⚠ 実況の振りに「いつの何の実況か」を分からせるため（#652）
  # - 自分の投稿のうち、`/chat/memory/hours` 以内のもの（返信・ブーストは除く・新しい順・`/chat/memory/max_posts` まで）。
  #   ⚠ 朝挨拶の本文は DB に残っていない（曲紹介の履歴は曲の鍵だけ）ので、**Mastodon に出たものを正本として引く**
  #
  # ## 🔴 引けなくても止めない
  #
  # 投稿が引けなければ「いま」だけを渡す（ログに残す）。⚠ 引けたものは `/chat/memory/refresh` のあいだ覚える
  # （メンションのたびに Mastodon を引かない）。
  class ChatMemory
    include Package

    WEEKDAYS = ['日', '月', '火', '水', '木', '金', '土'].freeze
    # ⚠ 1 本の上限（字）。曲紹介はリンクを除けば 150 字ほど。
    POST_MAX_LENGTH = 200
    # 渡す公開範囲（フォロワー限定・DM は渡さない — 会話の相手が見られない投稿を話さない）。
    VISIBILITIES = ['public', 'unlisted'].freeze

    # @param service [MastodonService, nil] ⚠ テストが差し替える
    def initialize(service: nil)
      @service = service
      @posts = nil
      @fetched_at = nil
    end

    # @param now [Time]
    # @return [String]
    def to_prompt(now = Time.now)
      lines = ['## いま', '', "#{self.class.format_time(now, date: true)}（日本時間）"]
      posts = recent_posts(now)
      if posts.any?
        lines.push('', '## 最近の自分の投稿（新しい順）', '',
          'あなた（真琴）が自分で投稿したもの。自分のしたこととして話してよい。', '')
        posts.each {|post| lines.push("- #{post[:at]}　#{post[:text]}")}
      end
      return lines.join("\n")
    end

    # @return [Array<Hash>] `{at:, text:}`
    def recent_posts(now = Time.now)
      since = now - (setting('hours').to_f * 60 * 60)
      posts = statuses(now).filter_map do |status|
        at = Time.parse(status['created_at'].to_s)
        next unless at >= since
        next unless VISIBILITIES.include?(status['visibility'])
        text = self.class.text_of(status)
        next if text.empty?
        {at: self.class.format_time(at, date: true), text: text}
      rescue ArgumentError
        next
      end
      return posts.first(setting('max_posts').to_i)
    end

    # 🔴 **ホストの TZ ではなく `/scheduler/timezone` で出す**（PR #665 の Codex の P2）— UTC のホストでは
    # 日曜 08:40 が土曜 23:40 になり、実況の曜日を取り違える（→ `MessageSelector#date_of` と同じ正本）。
    def self.format_time(time, date: false)
      zone = TZInfo::Timezone.get(Config.instance['/scheduler/timezone'])
      time = zone.utc_to_local(time.getutc)
      clock = time.strftime('%H:%M')
      return clock unless date
      return "#{time.strftime('%Y-%m-%d')}（#{WEEKDAYS[time.wday]}）#{clock}"
    end

    # ⚠ リンクは落とす（長いうえ、話の中身にならない）。
    def self.text_of(status)
      text = ChatThread.text_of(status).gsub(%r{https?://\S+}, '').gsub(/[ \t]+\n/, "\n")
      text = text.gsub(/\n{2,}/, "\n").strip.tr("\n", ' ')
      return text.length > POST_MAX_LENGTH ? "#{text[0, POST_MAX_LENGTH]}…" : text
    end

    private

    def statuses(now)
      return @posts if @posts && @fetched_at && (now - @fetched_at) < refresh_seconds
      @posts = service.own_statuses(limit: [setting('max_posts').to_i * 2, 40].min)
      @fetched_at = now
      return @posts
    rescue Ginseng::GatewayError, Ginseng::AuthError => e
      # ⚠ **失敗は覚えない**（次のメンションで引き直す）。前に引けたものがあればそれを使う。
      logger.warn(chat: 'memory', message: 'own statuses unavailable', error_class: e.class.name)
      return @posts || []
    end

    def refresh_seconds
      seconds = Fugit::Duration.parse(setting('refresh').to_s)&.to_sec
      return seconds if seconds&.positive?
      raise Ginseng::ConfigError, "chat: bad memory refresh '#{setting('refresh')}'"
    end

    def setting(key)
      return config["/chat/memory/#{key}"]
    end

    def service
      return @service ||= MastodonService.new
    end
  end
end
