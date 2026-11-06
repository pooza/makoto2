module Makoto
  class CureApiServiceTest < TestCase
    SINGERS = [
      {'name' => '宮本 佳那子', 'members' => []},
      {'name' => '五條 真由美', 'members' => []},
      {'name' => 'キュア・レインボーズ', 'members' => ['五條真由美', 'うちやえゆか', '工藤真由', '宮本佳那子']},
    ].freeze

    # ⚠⚠ **写しを持ち越さない**（#88）。⚠ **引けなかったときに写しで代わる**ので、
    # 前のテストが残した写しがあると「落ちても名義が返る」テストが素通しになる。
    # ⚠ **実際にこれで 2 本が落ちた**（＝写しが効いていることの裏返し）。
    setup do
      FileUtils.rm_f(CureApiService.cache_path)
    end

    teardown do
      FileUtils.rm_f(CureApiService.cache_path)
    end

    def setup
      super
      @url = config['/cure_api/url']
    end

    # ⚠ `return` に多行のチェインを繋げない（rubocop が 4 スペースを要求し、
    # 「インデントは論理構造だけ」の方針と衝突する → #80 の黄 12）。
    def stub_singers(records = SINGERS, status: 200)
      headers = {'Content-Type' => 'application/json'}
      return stub_request(:get, "#{@url}/singers").to_return(status: status, body: records.to_json, headers: headers)
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

    # 引けたものは写しに残す（#88）。
    def test_successful_fetch_is_stored
      stub_singers
      service.singer_names

      assert_path_exist(CureApiService.cache_path)
      assert_includes(JSON.parse(File.read(CureApiService.cache_path)), '宮本佳那子')
    end

    # 🔴 **#88 の本体。**⚠⚠ **`LiveProgram` はその日の並びを 1 回だけ組む**ので、
    # ⚠ **12:02 の一瞬の不通が「その日はゲストコーナーが無い」に直結していた。**
    # **一度でも引けていれば、落ちていても同じ名義で組めること。**
    def test_falls_back_to_the_stored_copy
      stub_singers
      expected = service.singer_names

      WebMock.reset!
      stub_request(:get, "#{@url}/singers").to_timeout
      api = service

      assert_equal(expected, api.singer_names)
      assert_predicate(api, :available?)
      # ⚠ **黙って古いもので組まない。**カバーを置く側が警告を出すために見る。
      assert_predicate(api, :stale?)
      assert(api.singer?('宮本佳那子'))
    end

    # ⚠⚠ **黙って古い写しで組まない**（#88）。⚠ **並びは保たれるが、名義が古いまま
    # かもしれない**ので、代わったこと自体はログに残す。
    def test_falling_back_is_reported
      stub_singers
      service.singer_names

      WebMock.reset!
      stub_request(:get, "#{@url}/singers").to_timeout
      api = service
      recorder = []
      api.instance_variable_set(:@logger, Struct.new(:x) do
        define_method(:warn) {|payload| recorder.push(payload[:message].to_s)}
        def error(*)
        end
      end.new(nil))
      api.singer_names

      assert_include(recorder, 'falling back to the stored copy')
    end

    # ⚠ 写しが無ければ、代わりようがないので空のまま（従来どおり）。
    def test_no_fallback_without_a_stored_copy
      stub_request(:get, "#{@url}/singers").to_timeout
      api = service

      assert_empty(api.singer_names)
      refute_predicate(api, :stale?)
    end

    # 🔴 **失敗を焼き付けない**（#88・#80 の黄 4）。⚠⚠ **旧実装は `||=` だったので、
    # 失敗時の `[]` も真になり、常駐を入れ直すまで二度と引き直さなかった。**
    def test_failure_is_not_burned_in
      stub_request(:get, "#{@url}/singers").to_timeout
      api = service

      assert_empty(api.singer_names)

      WebMock.reset!
      stub_singers
      # 間隔を過ぎたことにする（→ RETRY_INTERVAL）。
      api.instance_variable_set(:@failed_at, Time.now - CureApiService::RETRY_INTERVAL - 1)

      assert_includes(api.singer_names, '宮本佳那子')
    end

    # ⚠⚠ **かといって毎回引き直さない。**`singer?` は `select` の中から
    # ⚠ **曲の数だけ呼ばれる**（実データで 800 回超）ので、失敗を叩き続けると
    # そこが 800 回の HTTP になる。
    def test_repeated_failures_do_not_hammer_cure_api
      stub = stub_request(:get, "#{@url}/singers").to_timeout
      api = service
      5.times {api.singer_names}

      # ⚠ **飛ぶのは 1 回ぶんだけ**（`/http/retry/limit` の再送は HTTP 層の仕事）。
      # ⚠⚠ **5 回呼んでも 5 回ぶんにならないこと**を見ている。
      assert_requested(stub, times: config['/http/retry/limit'])
    end

    # ⚠ 壊れた写しを掴んで落ちない（読めなければ「写しは無い」と同じ扱い）。
    def test_broken_stored_copy_is_ignored
      FileUtils.mkdir_p(File.dirname(CureApiService.cache_path))
      File.write(CureApiService.cache_path, '{壊れた')
      stub_request(:get, "#{@url}/singers").to_timeout

      assert_empty(service.singer_names)
    end

    def test_normalize_strips_width_and_spaces
      assert_equal('宮本佳那子', CureApiService.normalize('宮本　佳那子'))
      assert_equal('abc', CureApiService.normalize('ａ ｂ ｃ'))
    end

    # 🔴 **数えるのは辞書に当たった歌手**（#157 の A+）。辞書は `/singers` の名義と構成員。
    CREDIT_SINGERS = [
      {'name' => '宮本 佳那子', 'members' => []},
      {'name' => '五條 真由美', 'members' => []},
      {'name' => '北川 理恵', 'members' => []},
      {'name' => 'Machico', 'members' => []},
      {'name' => '吉武 千颯', 'members' => []},
      {'name' => '石井 あみ', 'members' => []},
      {'name' => 'キュア・カルテット', 'members' => ['五條真由美', 'うちやえゆか', '工藤真由', '宮本佳那子']},
    ].freeze

    def credit_count(value)
      stub_singers(CREDIT_SINGERS)
      return service.credit_count(value)
    end

    # 🔴 **中黒 1 つで 2 人の形を数えられる**（#157 の発端・区切りで割る規則では原理的に当たらない）。
    def test_credit_count_finds_two_singers_joined_by_a_single_middle_dot
      assert_equal(2, credit_count('五條真由美・宮本佳那子'))
      assert_equal(2, credit_count('Machico/吉武千颯'))
    end

    # ⚠⚠ **名前の中の中黒で割らない**（`キュア・カルテット` は 1 組）。⚠ **長い名前から当てて
    # 消すので、構成員と二重に数えない。**
    def test_credit_count_keeps_a_group_as_one
      assert_equal(1, credit_count('キュア・カルテット'))
    end

    # ⚠⚠ **括弧の中の名前は数えない**（`CV:` の声優は「もう 1 人」ではない）。⚠ **辞書に居る
    # 名義の括弧は構成員の注記**なので、括弧そのものも数えない。
    def test_credit_count_ignores_names_inside_brackets
      assert_equal(1, credit_count('岬あやね(CV:Machico)'))
      assert_equal(1, credit_count('キュア・カルテット(五條真由美・宮本佳那子)'))
    end

    # 🔴 **括弧の注記が付いた名前は 1 人と数える**（2026-11-05・オーナー）。⚠⚠ **キャラクター名義の
    # デュエットを 1 人にしない。**
    def test_credit_count_counts_annotated_names
      assert_equal(2, credit_count('秋元こまち(CV:永野 愛) & 水無月かれん(CV:前田 愛)'))
      assert_equal(3, credit_count('本名陽子(なぎさ)&ゆかな(ほのか)&五條真由美'))
      assert_equal(2, credit_count('北川理恵 & 沖 佳苗(as キュアピーチ)'))
      assert_equal(2, credit_count('吉武千颯 with わんだふるぷりきゅあ!(CV:長縄まりあ・種﨑敦美)'))
      # ⚠ 同じ人物の 2 つの名前は 1 人。
      assert_equal(1, credit_count('水無月かれん/キュアアクア[CV:前田 愛]'))
    end

    # 🔴 **コーラス区画は先に落とす**（2026-09-07 の実測 — 落とさないと 3）。⚠ **英語の
    # `Chorus:` も同じ**（2026-11-05）。⚠ **括弧の中のコーラスを落とした跡は数えない。**
    def test_credit_count_ignores_the_chorus
      assert_equal(1, credit_count('北川理恵 コーラス:五條真由美・Machico'))
      assert_equal(1, credit_count('宮本佳那子/コーラス:ヤング・フレッシュ'))
      assert_equal(1, credit_count('吉武千颯 Chorus:北川理恵・Machico、プリキュア'))
      assert_equal(1, credit_count('北川理恵(コーラス:五條真由美、Machico)'))
    end

    # 🔴 **辞書に居ない名前は数えない**（作品名・非プリキュア歌手）。⚠ **作品名を「もう 1 組」と
    # 数えない。**
    def test_credit_count_ignores_names_outside_the_dictionary
      assert_equal(1, credit_count('石井あみ、キミとアイドルプリキュア♪'))
      assert_equal(2, credit_count('石井あみ・北川理恵、わんだふるぷりきゅあ!ざ・むーびー!'))
      assert_equal(1, credit_count('宮本佳那子 with ヤング・フレッシュ'))
    end

    # ⚠ 空でも、辞書に 1 つも当たらなくても 0 にしない（1 人扱い）。
    def test_credit_count_never_returns_zero
      assert_equal(1, credit_count(nil))
      assert_equal(1, credit_count(''))
      assert_equal(1, credit_count('内田順子, 山野さと子'))
    end

    # ⚠ **辞書が引けなければ全部 1 人**（そのときカバーは置かれないので重みに効かない）。
    def test_credit_count_without_the_dictionary
      stub_singers([], status: 500)

      assert_equal(1, service.credit_count('五條真由美・宮本佳那子'))
    end

    def stub_html(body = '<html><head><meta name="viewport"></head></html>')
      headers = {'Content-Type' => 'text/html'}
      return stub_request(:get, "#{@url}/singers").to_return(status: 200, body: body, headers: headers)
    end

    # 🔴 **#105 の本体。**⚠⚠ **200 で非 JSON が返ると `["name"]` が名義リストとして
    # 成立していた** — **`String#[]` が部分一致で substring を返す**ので、本文に
    # `name` の 4 文字があれば（`<meta name=...>` でまず含まれる）`record['name']` が
    # `"name"` を返す。⚠ **`available?` が真になるので「cure-api は生きているのに
    # 1 件も一致しない」と見え、誤診しやすい。**
    def test_a_non_json_body_is_rejected
      stub_html
      api = service

      assert_empty(api.singer_names)
      assert_false(api.available?)
    end

    # ⚠ 配列でも、中身が Hash でなければ同じく弾く（`['name']` が返る形）。
    def test_an_array_of_strings_is_rejected
      headers = {'Content-Type' => 'application/json'}
      stub_request(:get, "#{@url}/singers")
        .to_return(status: 200, body: ['name'].to_json, headers: headers)

      assert_empty(service.singer_names)
    end

    # 🔴 **汚れた写しを焼き付けない。**⚠⚠ **#88 の保険（cure-api が落ちていても
    # 並びを変えない）が、以後ずっと `["name"]` を返す形**になっていた。⚠ 写しを
    # 使い始めたら process 内では引き直さないので、**再起動しても写しが正のまま。**
    def test_a_malformed_response_keeps_the_stored_copy
      stub_singers
      expected = service.singer_names

      WebMock.reset!
      stub_html
      api = service

      assert_equal(expected, api.singer_names)
      # ⚠ 写しで代わったこと自体は従来どおり残る。
      assert_true(api.stale?)
      assert_includes(JSON.parse(File.read(CureApiService.cache_path)), '宮本佳那子')
    end

    # ⚠ 写しが無ければ書かない（`["name"]` がディスクに落ちない）。
    def test_a_malformed_response_does_not_write_a_copy
      stub_html
      service.singer_names

      assert_path_not_exist(CureApiService.cache_path)
    end

    # ⚠⚠ **黙って空にしない。**⚠ 「落ちている」と「200 で変なものを返している」は
    # 直し方が違うので、ログで区別できること。⚠ **本文は載せない**（HTML が丸ごと出る）。
    def test_a_malformed_response_is_reported
      stub_html
      api = service
      recorder = []
      api.instance_variable_set(:@logger, Struct.new(:x) do
        define_method(:warn) {|payload| recorder.push(payload)}
        def error(*)
        end
      end.new(nil))
      api.singer_names

      assert_include(recorder.map {|payload| payload[:message].to_s}, 'unexpected response shape')
      assert_equal('String', recorder.first[:type])
    end

    # ⚠ `members` が配列でなければ拾わない。⚠⚠ Hash だと `Array()` が組の配列を返し、
    # `[["name", "..."]]` のような値が名義に混ざる。
    def test_members_must_be_an_array
      stub_singers([{'name' => '宮本 佳那子', 'members' => {'a' => 'b'}}])

      assert_equal(['宮本佳那子'], service.singer_names)
    end
  end
end
