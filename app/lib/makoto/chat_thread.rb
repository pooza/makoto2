require 'cgi'

module Makoto
  # メンションの投稿と、その祖先（前のやりとり）から、LLM に渡す会話を組む（#18）。
  #
  # ## 🔴 前のやりとりを渡す（2026-10-29・オーナー了承 → #18）
  #
  # ⚠ 渡さないと、偽って持ち出された前の答えに乗る・相談の続きを読み違える・「その会話には、もう返事を
  # しない」（#510）が守れない（`tools/persona_eval/thread.yaml` の測定）。
  #
  # ## 組み方
  #
  # - MAKOTO の投稿は `assistant`、それ以外は `user`。⚠ 同じ側が続いたら 1 つにまとめる（API の決まり）
  # - 🔴 **会話が MAKOTO の投稿から始まるとき**（朝挨拶への返信など）は、その投稿を最初の `user` の頭に
  #   「〔あなたの投稿〕」として付ける（`config/chat/reply_format.md` に書いてある）。⚠ 会話の先頭は
  #   `user` でなければならない
  # - ⚠ MAKOTO 以外の話し手が 2 人以上いるときだけ、発言の頭に acct を付ける（誰が言ったかが要る）
  # - 本文は HTML を外し、先頭の宛先（`@makoto` など）を落とす
  # - ⚠ **祖先は新しい側から `/chat/thread/max_statuses` 件まで**（費用の歯止め）
  #
  # ## 🔴 第三者の閉じた投稿を渡さない（#613・v1.0.0 のリリース前レビュー）
  #
  # ⚠⚠ 祖先は MAKOTO のトークンで引くので、フォローを返した相手（#606）のフォロワー限定の投稿も読める。
  # 渡すと LLM が返事で言い換え、相手やタイムラインに漏れる。**MAKOTO と話しかけた本人以外の、
  # 公開・未収載でない祖先は会話に入れない。**⚠ 返事の公開範囲は、渡した投稿のうち最も狭いものに合わせる
  # （→ `visibility`）。⚠ 根（`root_id`）は落とす前の祖先で決める（会話を閉じた記録の鍵を変えない）
  #
  # 🔴 **MAKOTO 自身の DM も、話しかけた本人が宛先にいるときだけ渡す**（#641）。⚠⚠ リモートの相手は、MAKOTO が
  # 第三者に返した DM の URI を `inReplyTo` に入れてメンションできる。Mastodon は見えるかを確かめずに会話をつなぐので、
  # その DM が祖先として返り、中身の言い換えが相手へ漏れうる。⚠ 実地では確かめていない（塞ぐほうが安い）。
  # ⚠ MAKOTO のフォロワー限定は渡す（話しかけられるのはフォロワーだけ・門 → 本人にも見えている）
  #
  # ⚠⚠ **本文をログに出さない**（メンバーの書いたもの）。
  class ChatThread
    include Package

    OWN_POST_LABEL = '〔あなたの投稿〕'.freeze
    REPLY_LABEL = '〔それへの返信〕'.freeze

    # 広い順。⚠ 知らない値は最も狭いものとみなす。
    VISIBILITIES = ['public', 'unlisted', 'private', 'direct'].freeze
    OPEN_VISIBILITIES = ['public', 'unlisted'].freeze

    attr_reader :status, :ancestors

    # @param status [Hash] メンションの投稿（通知の `status`）
    # @param ancestors [Array<Hash>] 祖先（古い順）。⚠ 引けなければ空
    # @param own_id [String] MAKOTO のアカウント ID
    def initialize(status, ancestors, own_id:)
      @status = status
      @ancestors = Array(ancestors)
      @own_id = own_id.to_s
    end

    # スレッドの根の投稿の ID（→ `ChatRepository#close_thread`）。
    #
    # ⚠ **祖先が引けなかったときは、返信先（`in_reply_to_id`）で代える。**根に直接返信された形しか
    # 引き当たらないが、祖先は `read:statuses` で引ける（引けないのは Mastodon の不調のときだけ）。
    def root_id
      root = @ancestors.first || {}
      return root['id']&.to_s || @status['in_reply_to_id']&.to_s || @status['id'].to_s
    end

    # @return [Array<Hash>] `{role:, content:}` の並び。⚠ 最後は相手の投稿（`user`）
    def messages
      statuses = passed.filter_map {|entry| message(entry)}
      return merge(lead(statuses))
    end

    # 渡す投稿のうち最も狭い公開範囲（#613）。⚠ 返事はこれより広げない（→ `ChatResponder`）。
    def visibility
      narrowest = VISIBILITIES.size - 1
      index = passed.map {|entry| VISIBILITIES.index(entry['visibility'].to_s) || narrowest}.max
      return VISIBILITIES[index]
    end

    # 会話に入れる祖先（→ クラスの冒頭「第三者の閉じた投稿を渡さない」）。
    def visible_ancestors
      @visible_ancestors ||= @ancestors.reject {|entry| hidden?(entry)}
      return @visible_ancestors
    end

    # 🔴 **返事の本文の `@` をメンションにしない**（v1.0.0 のリリース前レビューの赤）。
    # ⚠⚠ LLM が「@xxx さんによろしく」と頼まれたり、指示を差し込まれたりして第三者の `@` を書くと、その相手に
    # 通知が届く（DM の会話なら DM として届く）。全角の `＠` に置き換える（読めるがメンションにならない）。
    def self.unmention(text)
      return text.to_s.gsub(/@(?=[[:word:]])/, '＠')
    end

    def self.text_of(status)
      html = status['content'].to_s
      html = html.gsub(%r{<br\s*/?>}i, "\n").gsub(%r{</p>\s*<p[^>]*>}i, "\n\n")
      text = CGI.unescapeHTML(html.gsub(/<[^>]+>/, ''))
      return text.sub(/\A(?:\s*@[\w.-]+(?:@[\w.-]+)?)+/, '').strip
    end

    private

    # LLM に渡す投稿（祖先は新しい側から上限まで ＋ メンション）。
    def passed
      @passed ||= visible_ancestors.last(limit) + [@status]
      return @passed
    end

    def hidden?(entry)
      return false if OPEN_VISIBILITIES.include?(entry['visibility'].to_s)
      author = entry.dig('account', 'id').to_s
      speaker = @status.dig('account', 'id').to_s
      return false if author == speaker
      return true unless author == @own_id
      return false if entry['visibility'].to_s == 'private'
      return Array(entry['mentions']).grep(Hash).none? {|mention| mention['id'].to_s == speaker}
    end

    def message(entry)
      text = self.class.text_of(entry)
      return nil if text.empty?
      own = entry.dig('account', 'id').to_s == @own_id
      text = "#{entry.dig('account', 'acct')}: #{text}" if !own && speakers > 1
      return {role: own ? 'assistant' : 'user', content: text}
    end

    def speakers
      @speakers ||= (visible_ancestors + [@status])
        .map {|entry| entry.dig('account', 'id').to_s}
        .reject {|id| id == @own_id}
        .uniq.size
      return @speakers
    end

    # 先頭の MAKOTO の投稿を、最初の相手の発言の頭へ寄せる。
    def lead(statuses)
      own = statuses.take_while {|entry| entry[:role] == 'assistant'}
      return statuses if own.empty?
      rest = statuses.drop(own.size)
      first = rest.shift
      return [] unless first
      own_text = own.map {|entry| entry[:content]}.join("\n\n")
      content = [OWN_POST_LABEL, own_text, '', REPLY_LABEL, first[:content]].join("\n")
      return [{role: 'user', content: content}] + rest
    end

    def merge(statuses)
      return statuses.each_with_object([]) do |entry, merged|
        if merged.last && merged.last[:role] == entry[:role]
          merged.last[:content] = "#{merged.last[:content]}\n\n#{entry[:content]}"
        else
          merged.push(entry.dup)
        end
      end
    end

    def limit
      return config['/chat/thread/max_statuses']
    end
  end
end
