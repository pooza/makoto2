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

    # 「マスクしているつもりで素通し」を防ぐ正テスト。実際に伏せられることを見る。
    def test_secure_dump_masks_secrets
      config['/mastodon/token'] = 'super-secret-token'
      dump = config.secure_dump

      assert_equal('(masked)', dump['/mastodon/token'])
      assert_not_include(dump.to_yaml, 'super-secret-token')
    end

    def test_secure_dump_keeps_other_values
      assert_equal(Package.version, config.secure_dump['/package/version'])
    end
  end
end
