module Makoto
  # 道具が使う cure-api の一覧（`/girls` と `/singers`・→ `ChatTools`）。
  # ⚠ `ChatTools` から切り出した（v1.2.0 のリリース前レビューで `Metrics/ClassLength` に当たった）。
  # ⚠ `@lists` / `http` / `config` / `logger` / `backing_off?` / `GIRLS_TTL` / `BackingOff` は
  # 取り込む側のもの。
  module ChatCureLists
    private

    # cure-api の一覧（`girls` / `singers`）。⚠ どちらも変わるのは新番組・辞書の手入れのときだけなので、`GIRLS_TTL` 持つ。
    #
    # ⚠ **引けたときだけ覚える**（失敗を覚えると、不通が常駐の寿命ぶん続く → `CureApiService#singer_names`）。
    # ⚠ 引けなければ、前に引けた一覧があればそれを使う（🔴 **期限が切れた後の取り直しに落ちたときも** —
    # v1.2.0 のリリース前レビューの黄。古い一覧を捨てて「引けませんでした」を返していた）。
    def list(path)
      state = @lists[path] ||= {}
      return state[:records] if fresh?(state)
      if backing_off?(state[:failed_at])
        return state[:records] if state[:records]
        raise self.class::BackingOff, 'cure-api: backing off'
      end
      begin
        return fetch_list(path, state)
      rescue => e
        raise unless state[:records]
        logger.warn(chat: 'tool', list: path, message: 'stale list', error_class: e.class.name)
        return state[:records]
      end
    end

    def fresh?(state)
      return false unless state[:records] && state[:at]
      return (Time.now - state[:at]) < self.class::GIRLS_TTL
    end

    def fetch_list(path, state)
      url = config['/cure_api/url'].to_s
      raise Ginseng::ConfigError, '/cure_api/url is missing' if url.empty?
      records = http.get("#{url}/#{path}").parsed_response
      unless records.is_a?(Array) && records.all?(Hash)
        raise Ginseng::GatewayError, "cure-api: unexpected /#{path}"
      end
      state[:at] = Time.now
      state[:failed_at] = nil
      return state[:records] = records
    rescue
      state[:failed_at] = Time.now
      raise
    end
  end
end
