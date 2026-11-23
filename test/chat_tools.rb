module Makoto
  class ChatToolsTest < TestCase
    GIRLS = [
      {girl_name: 'cure_black', precure_name: 'キュアブラック', human_name: '美墨 なぎさ', cast_name: '本名 陽子'},
      {girl_name: 'cure_sky', precure_name: 'キュアスカイ', human_name: 'ソラ・ハレワタール', cast_name: '関根 明良'},
      # ⚠ cure-api の `title` は作品名ではなく称号（v1.2.0 のリリース前レビューの赤）。
      {girl_name: 'cure_rosetta', precure_name: 'キュアロゼッタ', human_name: '四葉 ありす', cast_name: '渕上 舞',
       title: 'ひだまりポカポカ'},
    ].freeze

    def setup
      super
      @tools = ChatTools.new(tracks: TrackRepository.new(track_db))
      stub_singers
    end

    def girls_url
      return "#{config['/cure_api/url']}/girls"
    end

    def stub_girls(body = GIRLS.to_json)
      return stub_request(:get, girls_url).to_return(status: 200, body: body,
        headers: {'Content-Type' => 'application/json'})
    end

    SINGERS = [
      {name: '池田 彩', members: [], nicknames: ['あやさん']},
      {name: '工藤 真由', members: [], nicknames: ['くどまゆ', 'くどうしゃん', 'まゆちゃん']},
      {name: '五條 真由美', members: [], nicknames: ['まいこ', 'まゆちゃん']},
    ].freeze

    def singers_url
      return "#{config['/cure_api/url']}/singers"
    end

    def stub_singers(body = SINGERS.to_json)
      return stub_request(:get, singers_url).to_return(status: 200, body: body,
        headers: {'Content-Type' => 'application/json'})
    end

    def add_track(id, name, artist, released)
      track_db[:track].insert(id: id, name: name, artist_name: artist, kind: 'vocal',
        release_date: Date.parse(released), dedupe_key: TrackImporter.dedupe_key(name))
    end

    def rows(result)
      return JSON.parse(result.content)
    end

    # 🔴 **歌の曲だけを、新しい順に、同じ曲を 1 つにして返す**（劇伴・カラオケは「お勧めの曲」にならない）。
    def test_search_songs_returns_songs_newest_first
      result = @tools.call('search_songs', {'query' => ''})

      assert_false(result.error?)
      titles = rows(result).map {|row| row['title']}

      assert_equal('テストのうた　Ｍｙ　Ｔｒｕｅ　Ｌｏｖｅ！', titles.first)
      assert_equal(1, titles.count('しまうまグルグル'))
      assert_equal('2019-11-02', rows(result).first['released'])
      assert_equal(result.count, titles.size)
    end

    def test_search_songs_narrows_by_query
      titles = rows(@tools.call('search_songs', {'query' => 'しまうま'})).map {|row| row['title']}

      assert_equal(['しまうまグルグル'], titles)
    end

    # 🔴 **あだ名は本名に読み替えて、名義で引く**（#669・名義の空白の有無は問わない）。
    def test_search_songs_reads_a_nickname_as_the_singer
      stub_singers
      add_track(2001, 'HEART GOES ON', '池田 彩 & 工藤真由', '2011-01-26')
      add_track(2002, 'くどまゆのうた', 'だれか', '2011-01-27')
      titles = rows(@tools.call('search_songs', {'query' => 'くどまゆ'})).map {|row| row['title']}

      assert_equal(['HEART GOES ON'], titles)
    end

    # 🔴 **2 人以上に当たるあだ名・辞書に無い語は、語のまま引く**（推測で本名に結びつけない）。
    def test_search_songs_keeps_ambiguous_or_unknown_words
      stub_singers
      add_track(2001, 'HEART GOES ON', '池田 彩 & 工藤真由', '2011-01-26')
      add_track(2002, 'まゆちゃんのうた', 'だれか', '2011-01-27')

      assert_equal(['まゆちゃんのうた'], rows(@tools.call('search_songs', {'query' => 'まゆちゃん'})).map {|row| row['title']})
      assert_equal(['しまうまグルグル'], rows(@tools.call('search_songs', {'query' => 'しまうま'})).map {|row| row['title']})
    end

    # ⚠ `/singers` が引けなくても、道具は止めない（語のまま引く）。
    def test_search_songs_survives_without_singers
      stub_request(:get, singers_url).to_return(status: 503)

      assert_false(@tools.call('search_songs', {'query' => 'しまうま'}).error?)
    end

    # read_news の見出し（`ChatNews` の代わり）。
    class FakeNews
      def find(query)
        return nil unless query.include?('感謝祭')
        return ChatNews::Headline.new(at: '2026-11-16（月）13:35', title: '感謝祭 開催', source: 'A',
          url: 'https://news.example/a')
      end
    end

    class FakeArticle
      attr_reader :urls

      def initialize
        @urls = []
      end

      def read(url)
        @urls.push(url)
        return {title: '感謝祭', text: @text || '本文'}
      end

      attr_writer :text
    end

    # 🔴 **読みに行く先は、見出しに当たった記事の URL だけ**（#654）。
    def test_read_news_reads_only_the_headline_url
      config['/chat/news/enabled'] = true
      article = FakeArticle.new
      tools = ChatTools.new(tracks: TrackRepository.new(track_db), news: FakeNews.new, article:)
      result = tools.call('read_news', {'query' => '感謝祭'})

      assert_equal('本文', rows(result).first['text'])
      assert_equal(['https://news.example/a'], article.urls)
      assert_equal(0, tools.call('read_news', {'query' => 'https://evil.example/'}).count)
      assert_equal(['https://news.example/a'], article.urls)
    end

    # ⚠ 本文がほとんど取れなかったら、別の見出しへ回らせる。
    def test_read_news_notes_a_thin_article
      config['/chat/news/enabled'] = true
      article = FakeArticle.new
      tools = ChatTools.new(tracks: TrackRepository.new(track_db), news: FakeNews.new, article:)

      assert_include(rows(tools.call('read_news', {'query' => '感謝祭'})).first['note'], '別の見出し')
      article.text = 'あ' * ChatTools::THIN_ARTICLE_LENGTH

      assert_nil(rows(tools.call('read_news', {'query' => '感謝祭'})).first['note'])
    end

    def test_read_news_is_an_error_when_news_is_disabled
      config['/chat/news/enabled'] = false

      assert_true(@tools.call('read_news', {'query' => '感謝祭'}).error?)
    end

    # ⚠ LIKE の記号は文字として扱う（`%` で全部に当たらない）。
    def test_search_songs_escapes_like_wildcards
      assert_equal(0, @tools.call('search_songs', {'query' => '%'}).count)
    end

    def test_lookup_precure_matches_any_name
      stub_girls

      assert_equal(['キュアスカイ'], rows(@tools.call('lookup_precure', {'query' => '関根明良'})).map {|row| row['precure']})
      assert_equal(['キュアブラック'], rows(@tools.call('lookup_precure', {'query' => '美墨'})).map {|row| row['precure']})
      assert_equal([], rows(@tools.call('lookup_precure', {'query' => 'キュアミラクル'})))
    end

    # ⚠ **一覧は覚えておく**（毎回 cure-api を引かない）。
    def test_lookup_precure_caches_the_list
      stub_girls
      2.times {@tools.call('lookup_precure', {'query' => 'キュア'})}

      assert_requested(:get, girls_url, times: 1)
    end

    # 🔴 **引けなくても例外を上げない**（モデルには「引けなかった」と返す）。
    def test_a_failure_is_an_error_result
      stub_request(:get, girls_url).to_return(status: 200, body: '<html></html>',
        headers: {'Content-Type' => 'text/html'})
      result = @tools.call('lookup_precure', {'query' => 'キュアスカイ'})

      assert_true(result.error?)
      assert_equal(0, result.count)
    end

    def test_an_unknown_tool_is_an_error_result
      assert_true(@tools.call('drop_tables', {}).error?)
    end

    # ⚠ 全角の空白だけの語は空とみなす（#680 の緑・関係ない人を返していた）。
    def test_lookup_precure_ignores_blank_queries
      stub_girls

      assert_equal([], rows(@tools.call('lookup_precure', {'query' => '　'})))
    end

    # 🔴 **称号を渡さない**（cure-api の `title` は作品名ではない・v1.2.0 のリリース前レビューの赤）。
    def test_lookup_precure_does_not_pass_the_epithet
      stub_girls
      row = rows(@tools.call('lookup_precure', {'query' => 'ロゼッタ'})).first

      assert_equal('キュアロゼッタ', row['precure'])
      assert_false(row.key?('title'))
      assert_false(row.value?('ひだまりポカポカ'))
    end

    # 名前を 2 つ持つ 3 人（cure-api の `/girls` を変身前の名前と声優の組でまとめると、2 行以上はこの 3 組・#707）。
    TWO_FORMS = [
      {girl_name: 'cure_bloom', precure_name: 'キュアブルーム', human_name: '日向 咲', cast_name: '樹元 オリエ'},
      {girl_name: 'cure_egret', precure_name: 'キュアイーグレット', human_name: '美翔 舞', cast_name: '榎本 温子'},
      {girl_name: 'cure_bright', precure_name: 'キュアブライト', human_name: '日向 咲', cast_name: '樹元 オリエ'},
      {girl_name: 'cure_windy', precure_name: 'キュアウィンディ', human_name: '美翔 舞', cast_name: '榎本 温子'},
      {girl_name: 'cure_arcana_shadow', precure_name: 'キュアアルカナ・シャドウ', human_name: '森亜 るるか',
       cast_name: '東山 奈央'},
      {girl_name: 'cure_arcana', precure_name: 'キュアアルカナ', human_name: '森亜 るるか', cast_name: '東山 奈央'},
    ].freeze

    # 🔴 **同じ人の別の姿は 1 人にまとめ、片方で引いてももう片方を添える**（#707）。
    def test_lookup_precure_joins_the_forms_of_one_person
      stub_girls((GIRLS + TWO_FORMS).to_json)

      arcana = rows(@tools.call('lookup_precure', {'query' => 'アルカナ'}))

      assert_equal(1, arcana.size)
      assert_equal(['キュアアルカナ・シャドウ', 'キュアアルカナ'], arcana.first['forms'])
      assert_equal('森亜 るるか', arcana.first['name'])
      assert_equal(['キュアブルーム', 'キュアブライト'], rows(@tools.call('lookup_precure', {'query' => 'ブライト'})).first['forms'])
      assert_equal(['キュアイーグレット', 'キュアウィンディ'], rows(@tools.call('lookup_precure', {'query' => 'イーグレット'})).first['forms'])
      assert_equal(2, rows(@tools.call('lookup_precure', {'query' => 'キュアブ'})).size)
    end

    # ⚠ 姿が 1 つの人には `forms` を付けない。⚠ 変身前の名前か声優が空の行はまとめない（取り違えない）。
    def test_lookup_precure_keeps_single_forms_apart
      stub_girls((GIRLS + [
        {girl_name: 'cure_a', precure_name: 'キュアエー', human_name: '', cast_name: '同じ 声'},
        {girl_name: 'cure_b', precure_name: 'キュアビー', human_name: '', cast_name: '同じ 声'},
      ]).to_json)

      assert_false(rows(@tools.call('lookup_precure', {'query' => 'スカイ'})).first.key?('forms'))
      assert_equal(['キュアエー', 'キュアビー'], rows(@tools.call('lookup_precure', {'query' => '同じ声'})).map {|row| row['precure']})
    end

    # 🔴 **期限が切れた後の取り直しに落ちても、前に引けた一覧を使う**（v1.2.0 のリリース前レビューの黄）。
    def test_a_stale_list_is_used_when_refetching_fails
      stub_girls
      @tools.call('lookup_precure', {'query' => 'スカイ'})
      @tools.instance_variable_get(:@lists)['girls'][:at] = Time.now - ChatTools::GIRLS_TTL - 1
      stub_request(:get, girls_url).to_return(status: 503)
      result = @tools.call('lookup_precure', {'query' => 'スカイ'})

      assert_false(result.error?)
      assert_equal(['キュアスカイ'], rows(result).map {|row| row['precure']})
    end

    # 🔴 **ニュースを切っている間は `read_news` を渡さない**（v1.2.0 のリリース前レビューの黄）。
    def test_definitions_drop_read_news_while_news_is_disabled
      config['/chat/news/enabled'] = true

      assert_includes(ChatTools.definitions.map {|definition| definition[:name]}, 'read_news')
      config['/chat/news/enabled'] = false

      assert_not_include(ChatTools.definitions.map {|definition| definition[:name]}, 'read_news')
      assert_includes(ChatTools.definitions.map {|definition| definition[:name]}, 'lookup_precure')
    end

    # 🔴 **引けなかったら、しばらく cure-api を引きに行かない**（#680 の B1）。⚠ そのあいだは Sentry へ送らない。
    def test_a_failure_backs_off
      stub_request(:get, girls_url).to_return(status: 503)

      assert_true(@tools.call('lookup_precure', {'query' => 'キュアスカイ'}).error?)
      assert_true(@tools.call('lookup_precure', {'query' => 'キュアスカイ'}).error?)
      assert_requested(:get, girls_url, times: 1)
    end

    # ⚠ 外の口は短く待ち、リトライしない（#680 の B1）。
    def test_the_default_http_waits_briefly
      http = ChatTools.new.send(:http)

      assert_equal(config['/chat/lookup/timeout'], http.timeout)
      assert_equal(0, http.retry_limit)
    end
  end
end
