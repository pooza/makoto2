require 'json-schema'

module Makoto
  class ConfigTest < TestCase
    def test_version
      assert_match(/^\d+\.\d+\.\d+$/, Package.version)
      assert_equal("makoto2 #{Package.version}", Package.full_name)
    end

    def test_schema
      assert_empty(config.errors)
    end

    # ⚠ 「スキーマが通ったのに投稿の瞬間に落ちる」を防ぐ正テスト。`/mastodon/url` と
    # `/mastodon/token` が無い設定を、実際に `rake config:lint` が弾くことを見る。
    def test_schema_rejects_mastodon_without_credentials
      schema = YAML.load_file(File.join(Makoto.dir, 'config/schema/base.yaml'))
      payload = config.merged_raw.deep_dup
      payload['mastodon'] = {'acct' => 'makoto'}

      assert_not_empty(JSON::Validator.fully_validate(schema, payload))
    end

    # `format: uri` は相対参照も許すので、HTTP(S) の typo を実際に弾くことを見る。
    def test_schema_rejects_invalid_service_url_schemes
      schema = YAML.load_file(File.join(Makoto.dir, 'config/schema/base.yaml'))
      application = YAML.load_file(File.join(Makoto.dir, 'config/application.yaml'))
      local = YAML.load_file(File.join(Makoto.dir, 'config/local_sample.yaml'))
      valid_payload = Hash.deep_merge(application, local)

      ['cure_api', 'mastodon', 'package'].each do |section|
        payload = valid_payload.deep_dup
        payload[section]['url'] = 'htps://example.invalid'

        assert_not_empty(
          JSON::Validator.fully_validate(schema, payload),
          "#{section}.url accepted an invalid HTTP(S) scheme",
        )
      end
    end

    # ⚠⚠ **運用上必須の設定が、消しても `rake config:lint` を通らないこと。**
    # ⚠ **「親キーだけを required にしても、中身が欠けた設定は通り抜ける」**という
    # 逆も見る（→ docs/CLAUDE.md のコーディング規約）。
    #
    # ⚠ `/http` は **`origin/main` からの持ち越しで schema に無かった**（#80 の緑 3）。
    # ⚠⚠ **`timeout` が欠けると 1 本の投稿が既定の 60 秒 × 再送で枠を跨ぐ**（#90 で
    # 塞いだところがそのまま戻る）。
    def test_schema_requires_the_operational_settings
      schema = YAML.load_file(File.join(Makoto.dir, 'config/schema/base.yaml'))
      valid = config.merged_raw.deep_dup

      [
        ['http'], ['http', 'retry'], ['http', 'timeout'], ['http', 'timeout', 'seconds'],
        ['logger', 'level'], ['scheduler', 'tick_stale'], ['scheduler', 'tolerance']
      ].each do |path|
        payload = valid.deep_dup
        parent = path.size > 1 ? payload.dig(*path[0..-2]) : payload
        parent.delete(path.last)

        assert_not_empty(
          JSON::Validator.fully_validate(schema, payload),
          "/#{path.join('/')} was accepted as missing",
        )
      end
    end

    # 「マスクしているつもりで素通し」を防ぐ正テスト。実際に伏せられることを見る。
    # ⚠ `errors` は `@raw`（読み込んだファイル）を検証するので、⚠⚠ **`config['/x'] = y`
    # では変わらない**（`Config < Hash` の平坦化された側だけが動く）。**差し替えて見る。**
    def with_errors(found)
      config.define_singleton_method(:errors) {found.call}
      return yield
    ensure
      config.singleton_class.remove_method(:errors)
    end

    # 🔴 **設定の検証は 1 回だけ回して覚える**（#99）。⚠⚠ **`errors` は呼ぶたびに
    # schema 全体を回す**ので、⚠ **60 秒間隔の監視から素で呼ぶと CPU を使い続ける**
    # （`Health` はリクエストごとに作られる → `MonitorApp`）。
    def test_validation_errors_are_memoised
      calls = 0
      counter = lambda do
        calls += 1
        []
      end
      with_errors(counter) do
        3.times {config.validation_errors}
      end

      assert_equal(1, calls)
    end

    # ⚠ schema の URI までログに載せない（読む側の役に立たないうえ長い）。
    def test_validation_errors_drop_the_schema_uri
      found = ['The property \'#/mastodon\' did not contain a required property in schema abc123']

      with_errors(-> {found}) do
        assert_equal(["The property '#/mastodon' did not contain a required property"],
          config.validation_errors)
      end
    end

    # ⚠ 書き換えたら捨てる。⚠⚠ **覚えたまま古い判定を返し続けない。**
    def test_reload_forgets_the_validation
      found = ['壊れています in schema abc123']
      with_errors(-> {found}) do
        assert_not_empty(config.validation_errors)
        found = []

        assert_not_empty(config.validation_errors, '覚えている間は変わらない')
        config.reload

        assert_empty(config.validation_errors)
      end
    end

    def test_secure_dump_masks_secrets
      config['/mastodon/token'] = 'super-secret-token'
      dump = config.secure_dump

      assert_equal('(masked)', dump['/mastodon/token'])
      assert_not_include(dump.to_yaml, 'super-secret-token')
    end

    def test_secure_dump_keeps_other_values
      assert_equal(Package.version, config.secure_dump['/package/version'])
    end

    # 🔴 **落とす列がログ側とずれないこと**（#216）。⚠⚠ **`makoto config` は
    # `/logger/mask_fields` だけを見ており、上流が `ginseng-core#586` で広げた
    # 既定が届いていなかった** — ⚠ **ログでは伏せるのに CLI では平文**という形。
    #
    # ⚠ **実データでは 0 件だが、その名前のキーを設定に足した日に戻る**ので、
    # **「いま当たっていない」ではなく「同じ列を見ている」ほうを見る。**
    def test_secure_dump_masks_every_field_the_logger_masks
      fields = logger.mask_fields
      fields.each {|field| config["/masking_test/#{field}"] = 'S3CRET'}
      dump = config.secure_dump

      fields.each do |field|
        assert_equal('(masked)', dump["/masking_test/#{field}"], "#{field} が伏せられていない")
      end
      assert_not_include(dump.to_yaml, 'S3CRET')
    end

    # ⚠⚠ **上流の既定にあって `config/application.yaml` に無いキー**が対象。
    # 🔴 **設定単独を正本にしていたころ、ここが素通りしていた**（#216 の実測では
    # `apikey` / `client_secret` / `refresh_token` の 3 件）。
    def test_secure_dump_masks_the_upstream_defaults_absent_from_the_config
      configured = config['/logger/mask_fields'].map {|field| field.to_s.downcase}
      upstream_only = logger.mask_fields.reject {|field| configured.include?(field)}

      assert_not_empty(upstream_only, '上流の既定がすべて設定にも並んでいる（この正テストが空回りする）')
      upstream_only.each do |field|
        config["/masking_test/#{field}"] = 'S3CRET'

        assert_equal('(masked)', config.secure_dump["/masking_test/#{field}"])
      end
    end

    # 🔴 **`code` は上流が意図して既定から外している**（Hash のキーとしては
    # ステータスコードが普通に入る → #213）。⚠⚠ **こちらの列挙が唯一の根拠**なので、
    # **合成へ寄せたときに落としていないことを見る。**
    def test_secure_dump_keeps_masking_the_locally_configured_field
      config['/masking_test/code'] = 'S3CRET'

      assert_equal('(masked)', config.secure_dump['/masking_test/code'])
    end

    # ⚠ **上流の `mask_field?` は `key.to_s.downcase` で見る。**⚠⚠ **ここだけ
    # 完全一致にすると、ログでは伏せるのに CLI では平文**になる（v0.4.0 の
    # リリース前レビューで上流が実測した形と同じ）。
    def test_secure_dump_ignores_the_case_of_the_key
      config['/masking_test/Token'] = 'S3CRET'
      config['/masking_test/AUTHORIZATION'] = 'S3CRET'
      dump = config.secure_dump

      assert_equal('(masked)', dump['/masking_test/Token'])
      assert_equal('(masked)', dump['/masking_test/AUTHORIZATION'])
    end
  end
end
