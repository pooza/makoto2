module Makoto
  class ChatThreadTest < TestCase
    OWN = '100'.freeze

    def post(id, account_id, html, acct: "user#{account_id}", reply_to: nil)
      return {
        'id' => id,
        'in_reply_to_id' => reply_to,
        'content' => html,
        'account' => {'id' => account_id, 'acct' => acct},
      }
    end

    def mention(html = '<p><span class="h-card"><a href="x">@<span>makoto</span></a></span> 猫派？</p>', **)
      return post('9', '1', html, **)
    end

    def test_text_drops_html_and_the_leading_mention
      html = '<p><span class="h-card"><a href="x">@<span>makoto</span></a></span> こんにちは&amp;' \
        'よろしく<br>2 行目</p><p>3 行目</p>'

      assert_equal("こんにちは&よろしく\n2 行目\n\n3 行目", ChatThread.text_of({'content' => html}))
    end

    def test_a_single_mention
      thread = ChatThread.new(mention, [], own_id: OWN)

      assert_equal([{role: 'user', content: '猫派？'}], thread.messages)
      assert_equal('9', thread.root_id)
    end

    # 🔴 **前のやりとりを渡す**（2026-10-29・オーナー了承）。
    def test_ancestors_become_the_history
      ancestors = [
        post('1', '1', '<p>@makoto 犬派？猫派？</p>'),
        post('2', OWN, '<p>@user1 猫かな。</p>', acct: 'makoto', reply_to: '1'),
      ]
      thread = ChatThread.new(mention('<p>@makoto なんでそっちなの？</p>', reply_to: '2'), ancestors, own_id: OWN)

      assert_equal([
        {role: 'user', content: '犬派？猫派？'},
        {role: 'assistant', content: '猫かな。'},
        {role: 'user', content: 'なんでそっちなの？'},
      ], thread.messages)
      assert_equal('1', thread.root_id)
    end

    # 🔴 **MAKOTO の投稿から始まる会話**（朝挨拶への返信など）は、最初の相手の発言の頭に寄せる。
    def test_a_thread_starting_with_an_own_post
      ancestors = [post('1', OWN, '<p>おはよう！みんな、元気してるかな？</p>', acct: 'makoto')]
      thread = ChatThread.new(mention('<p>@makoto おはよう！</p>', reply_to: '1'), ancestors, own_id: OWN)

      assert_equal([{role: 'user', content: "〔あなたの投稿〕\nおはよう！みんな、元気してるかな？\n\n〔それへの返信〕\nおはよう！"}],
        thread.messages)
    end

    def test_same_roles_are_merged
      ancestors = [post('1', '1', '<p>@makoto ねえ</p>'), post('2', '1', '<p>@makoto 聞いてる？</p>', reply_to: '1')]
      thread = ChatThread.new(mention('<p>@makoto おーい</p>', reply_to: '2'), ancestors, own_id: OWN)

      assert_equal([{role: 'user', content: "ねえ\n\n聞いてる？\n\nおーい"}], thread.messages)
    end

    # ⚠ 話し手が 2 人以上いるときだけ、誰が言ったかを付ける。
    def test_speakers_are_named_when_there_are_several
      ancestors = [post('1', '2', '<p>@makoto 好きな食べ物は？</p>', acct: 'other')]
      thread = ChatThread.new(mention('<p>@makoto 私も知りたい</p>', reply_to: '1'), ancestors, own_id: OWN)

      assert_equal([{role: 'user', content: "other: 好きな食べ物は？\n\nuser1: 私も知りたい"}], thread.messages)
    end

    def test_ancestors_are_limited_from_the_newest
      config['/chat/thread/max_statuses'] = 1
      ancestors = [post('1', '1', '<p>古い</p>'), post('2', OWN, '<p>新しい</p>', reply_to: '1')]
      thread = ChatThread.new(mention('<p>@makoto 次</p>', reply_to: '2'), ancestors, own_id: OWN)

      assert_equal("〔あなたの投稿〕\n新しい\n\n〔それへの返信〕\n次", thread.messages.first[:content])
      assert_equal('1', thread.root_id)
    end

    # ⚠ 祖先が引けなかったときは、返信先で代える。
    def test_the_root_falls_back_to_the_reply_target
      assert_equal('5', ChatThread.new(mention(reply_to: '5'), [], own_id: OWN).root_id)
    end
  end
end
