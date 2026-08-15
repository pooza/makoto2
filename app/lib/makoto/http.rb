module Makoto
  # HTTP の口。⚠ **タイムアウトをここで渡す**（#90）。
  #
  # ⚠⚠ **`Ginseng::HTTP` が HTTParty に `timeout:` を渡しているのは `upload` だけ。**
  # ⚠ **`get` / `post` は素通しなので、実効は Net::HTTP 既定の 60 秒**だった
  # （`/http/timeout/seconds: 30` は設定に在るのに効いていない → #80 の黄 2）。
  #
  # ⚠⚠ **再送 3 回と合わせて 1 本の投稿が最悪 182 秒。****ライブの枠間隔 180 秒と
  # ほぼ同じ**で、⚠ **tick のスレッドを占有する。**
  #
  # ⚠ **二重投稿の危険は無い**（`Net::ReadTimeout` は再送しない設計なので、
  # 「受理されたが応答だけ失われた」経路は塞がれている）。**問題は枠を跨ぐ滞留のほう。**
  #
  # ⚠ **本筋は ginseng-core を直すこと**だが、⚠⚠ **利用者が 2 つになった**（→ #37）
  # ので、**上流は別に起票し、こちらは自分の箱で塞ぐ。**
  class HTTP < Ginseng::HTTP
    include Package

    def head(uri, options = {})
      return super(uri, with_timeout(options))
    end

    def get(uri, options = {})
      return super(uri, with_timeout(options))
    end

    def post(uri, options = {})
      return super(uri, with_timeout(options))
    end

    def put(uri, options = {})
      return super(uri, with_timeout(options))
    end

    def delete(uri, options = {})
      return super(uri, with_timeout(options))
    end

    def timeout_seconds
      return config['/http/timeout/seconds']
    end

    private

    # ⚠ **呼ぶ側が明示した値を上書きしない。**⚠⚠ **`upload` は元から自分で渡している**
    # ので、そこを奪わない。
    def with_timeout(options)
      return options if options.key?(:timeout)
      return options.merge(timeout: timeout_seconds)
    end
  end
end
