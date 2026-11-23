module Makoto
  # LLM の使用量と、その費用の見積もり（→ `ChatModel`）。
  # ⚠ `ChatModel` から切り出した（#701 で `Metrics/ClassLength` に当たった）。⚠ `setting` は取り込む側のもの。
  module ChatUsage
    # 使用量の見積もり（USD）。⚠ ログで見直すための目安で、請求額ではない。
    # ⚠ `input_tokens` はキャッシュから読んだ分・書いた分を含まない（別に数える）。
    def cost(usage)
      total = [
        usage[:input_tokens].to_i * setting('price/input').to_f,
        usage[:output_tokens].to_i * setting('price/output').to_f,
        usage[:cache_read].to_i * setting('price/cache_read').to_f,
        usage[:cache_write].to_i * setting("price/cache_write/#{setting('cache_ttl')}").to_f,
      ].sum
      return (total / 1_000_000).round(5)
    end

    private

    def add_usage(total, usage)
      return usage if total.empty?
      return total unless usage.any?
      merged = total.merge(usage) do |key, a, b|
        key == :model ? b : a.to_i + b.to_i
      end
      return merged
    end

    def usage_of(response)
      usage = response.usage
      return {} unless usage
      return {
        input_tokens: usage.input_tokens,
        output_tokens: usage.output_tokens,
        cache_read: usage.cache_read_input_tokens.to_i,
        cache_write: usage.cache_creation_input_tokens.to_i,
        model: response.model.to_s,
      }
    end
  end
end
