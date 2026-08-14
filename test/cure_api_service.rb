module Makoto
  class CureApiServiceTest < TestCase
    SINGERS = [
      {'name' => '宮本 佳那子', 'members' => []},
      {'name' => '五條 真由美', 'members' => []},
      {'name' => 'キュア・レインボーズ',
       'members' => ['五條真由美', 'うちやえゆか', '工藤真由', '宮本佳那子']},
    ].freeze

    def setup
      super
      @url = config['/cure_api/url']
    end

    def stub_singers(records = SINGERS, status: 200)
      return stub_request(:get, "#{@url}/singers")
          .to_return(status: status, body: records.to_json,
            headers: {'Content-Type' => 'application/json'})
    end

    def service
      return CureApiService.new
    end

    # ⚠ グループ名だけでなく**構成員も引く**。曲データの名義は構成員が並んで
    # 書かれることがあり、グループ名だけでは照合できない。
    def test_singer_names_include_members
      stub_singers
      names = service.singer_names

      assert_includes(names, '宮本佳那子')
      assert_includes(names, 'キュア・レインボーズ')
      assert_includes(names, 'うちやえゆか')
    end

    # ⚠⚠ **スプレッドシートは「宮本 佳那子」、曲データは「宮本佳那子」。**
    # ここが噛み合わないと 1 件も一致しない。
    def test_spacing_is_normalized
      stub_singers

      assert(service.singer?('宮本佳那子'))
    end

    # ⚠⚠ **曲データの `artist_name` は 1 名義とは限らない。**区切って、どれか 1 つでも
    # 辞書に居れば真とする。
    def test_matches_inside_a_compound_artist_name
      stub_singers
      api = service

      assert(api.singer?('キュア・レインボーズ(五條真由美・うちやえゆか・工藤真由)'))
      assert(api.singer?('吉武千颯&礒部花凜/北川理恵/駒形友梨/宮本佳那子'))
      assert(api.singer?('花奈〈CV: 宮本 佳那子〉'))
    end

    # ⚠⚠ **区切り文字を名前の中に持つ名義**（辞書 66 件中 6 件）。⚠ **いきなり割ると
    # 「キュア」＋「レインボーズ」になって、どちらも辞書に無い＝落ちる。**
    # ⚠ 実データでは「キュア・カルテット」の 9 行がカバー母集合から落ちていた。
    def test_group_name_containing_a_delimiter
      stub_singers

      assert(service.singer?('キュア・レインボーズ'))
    end

    # ⚠ **カラオケレーベルやオルゴール盤は辞書に居ないので落ちる。**曲データの
    # `kind` は当てにならない（歌っちゃ王 125 曲のうち 83 曲が vocal → #56）ので、
    # **名義の側で落とすこと**がこの機能の要。
    def test_rejects_names_outside_the_dictionary
      stub_singers
      api = service

      refute(api.singer?('歌っちゃ王'))
      refute(api.singer?('DANZEN!ふたりはプリキュア +2Key(原曲歌手:五條真由美)'))
      refute(api.singer?('オルゴールサウンド J-POP'))
    end

    # ⚠⚠ **cure-api が落ちてもライブは止めない。**ただし黙らない（警告を残す）。
    # ⚠ available? が false なら Setlist はカバーを置かない。
    def test_survives_an_unreachable_cure_api
      stub_request(:get, "#{@url}/singers").to_timeout
      api = service

      assert_empty(api.singer_names)
      refute_predicate(api, :available?)
      refute(api.singer?('宮本佳那子'))
    end

    # ⚠⚠ **404 を成功として扱わない。**cure-api は未知のパスに HTTP 200 と
    # `<h1>Not Found</h1>` を返していた時期があり、**HTML を JSON として扱って
    # 黙って 0 件**になった（cure-api 3.1.0 で修正）。⚠ 空で返るのは同じでも、
    # **警告が残ること**が違う。
    def test_html_body_does_not_become_a_singer
      stub_request(:get, "#{@url}/singers")
        .to_return(status: 200, body: '<h1>Not Found</h1>',
          headers: {'Content-Type' => 'text/html'})

      assert_empty(service.singer_names)
    end

    def test_error_status_is_not_a_singer_list
      stub_singers([], status: 500)

      assert_empty(service.singer_names)
    end

    # ⚠ 1 回のプロセスで何度も引かない（8 時間のライブ中に叩き続けない）。
    def test_result_is_cached
      stub = stub_singers
      api = service
      3.times {api.singer_names}

      assert_requested(stub, times: 1)
    end

    def test_normalize_strips_width_and_spaces
      assert_equal('宮本佳那子', CureApiService.normalize('宮本　佳那子'))
      assert_equal('abc', CureApiService.normalize('ａ ｂ ｃ'))
    end
  end
end
