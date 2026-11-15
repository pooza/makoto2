module Makoto
  class ChatToolsTest < TestCase
    GIRLS = [
      {girl_name: 'cure_black', precure_name: 'キュアブラック', human_name: '美墨 なぎさ', cast_name: '本名 陽子'},
      {girl_name: 'cure_sky', precure_name: 'キュアスカイ', human_name: 'ソラ・ハレワタール', cast_name: '関根 明良'},
    ].freeze

    def setup
      super
      @tools = ChatTools.new(tracks: TrackRepository.new(track_db))
    end

    def girls_url
      return "#{config['/cure_api/url']}/girls"
    end

    def stub_girls(body = GIRLS.to_json)
      return stub_request(:get, girls_url).to_return(status: 200, body: body,
        headers: {'Content-Type' => 'application/json'})
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
  end
end
