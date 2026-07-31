require 'webmock'

module Makoto
  class TestCase < Ginseng::TestCase
    include Package
    include WebMock::API

    # ⚠ テストから外部へ実際のリクエストを飛ばさない。MAKOTO は投稿するボットなので、
    # 取りこぼすと本物のサーバーに書き込む（実際に 10 通投げてしまった）。
    #
    # `require 'webmock'` だけでは HTTP アダプタは差し替わらない。**`WebMock.enable!` を
    # 呼ぶまで `disable_net_connect!` も stub_request も無言で素通りする。**
    #
    # ⚠ **`setup` メソッドではなくコールバックで登録する。**メソッドにすると、
    # サブクラスが `setup` を定義して `super` を忘れた瞬間に遮断が外れる。
    # 忘れても落ちないので、素通しになったことに気付けない。
    setup do
      WebMock.enable!
      WebMock.disable_net_connect!
    end

    teardown do
      WebMock.reset!
      WebMock.allow_net_connect!
      WebMock.disable!
      @empty_db&.disconnect
      config.reload
    end

    # テスト用のコーパス。**メモリ上に作って捨てる。**
    # 開発用の `tmp/db/makoto.db` を掴むと、投入済みのコーパスを壊す。
    #
    # 中身は [test/fixture/corpus/](../../../test/fixture/corpus/) の作り物。
    # ⚠ **実データを fixture に置かない。**このリポジトリは public で、本編の
    # 台詞は第三者の著作物（`var/` をコミットしないのと同じ理由）。
    def corpus_db
      unless @corpus_db
        @corpus_db = empty_db
        CorpusImporter.new(corpus_fixture_dir, db: @corpus_db).exec
      end
      return @corpus_db
    end

    # スキーマだけ当てた空の DB。投入そのものを見るテストが使う。
    def empty_db
      @empty_db ||= Database.migrate(Database.connect('sqlite:/'))
      return @empty_db
    end

    def corpus_fixture_dir
      return File.join(self.class.fixture_dir, 'corpus')
    end

    def self.dir
      return File.join(Environment.dir, 'test')
    end
  end
end
