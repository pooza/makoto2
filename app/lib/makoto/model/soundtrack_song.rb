module Makoto
  # サントラ盤に入っている歌を、名義で見分けて `bgm` から外す規則（#497）。⚠ **あわせて、`vocal` に
  # 入っている短縮版を `tv_size` に移す**（下記「`vocal` の短縮版」）。
  #
  # ⚠⚠ **収集側の `bgm` はアルバム名だけで決まる**（`seed/track_kind.py` — 「サウンドトラック」
  # 「サントラ」「音楽集」など）。🔴 **サントラ盤には主題歌の映画サイズ・挿入歌・キャラクター
  # ソングも入っている**ので、それらが劇伴として扱われていた（2026-10-05 の曲紹介で
  # 『鮮烈!キュアモフルン』が劇伴の前置きで出た）。
  #
  # ## 規則（2026-11-05・オーナー判断）
  #
  # - **歌と見るのは、名義が歌手のもの**（cure-api の `/singers` に当たる → `CureApiService#singer?`）
  #   **か、`CV:` / `CV.` 表記のキャラクター名義のもの。**⚠ **作曲家は `/singers` に入っていない**
  #   ので、劇伴が歌に化けない
  # - 🔴 **短縮版は `tv_size`、それ以外は `vocal`**（全部 `vocal` にすると、主題歌の短縮版が本体と
  #   並んで `vocal` の枠に出る）
  #   - ⚠ **「映画version」「劇場Version」「Movie version」「DX3 version」も短縮版**（実測で 1:19〜2:49）
  #   - ⚠⚠ **変身バンクの歌（0:43〜0:57）は `vocal`** — 短いが、それで全部の歌であって短縮版ではない。
  #     **長さでは切らない**
  #
  # ## `vocal` の短縮版（2026-11-05・オーナー判断）
  #
  # 🔴 **「短縮版は `tv_size`」はサントラ盤の外にも当てる。**⚠⚠ **収集側の `tv_size` は「TV サイズ」しか
  # 見ない**ので、シングル盤やボーカルアルバムの「(Shortサイズ)」「Short Ver.」「(映画サイズ)」が
  # `vocal` に入っていた（2026-11-05 の実測で既存 7 行・#308 の新しい行 2 行）。⚠ **名義は問わない**
  # （`vocal` の行はもともと歌）。
  #
  # ⚠ **作品名が名義の古い盤**（無印 MH / S☆S / 5 / 5GoGo）は名義では判定できない。**そこにある歌は
  # `seed/track_kinds.yaml` で行ごとに正す。**
  class SoundtrackSong
    # 🔴 **キャラクター名義**（`キュアスター(CV.成瀬瑛美)`）。⚠ NFKC の後で見る。
    CHARACTER = /CV\s*[:.]/i

    # 🔴 **短縮版の印**（NFKC の後で見る）。⚠ `TV\s*(サイズ|size)` は収集側の `tv_size` と同じ形
    # （サントラ盤の中にもある — 収集側は `bgm` より先に当たるので、ここに来るのは
    # 「映画サイズ」などの形）。
    #
    # ⚠ **「DX3 version」も短縮版**（『映画プリキュアオールスターズDX3』のサントラ・1:19〜1:27）。
    # ⚠⚠ **いまの曲データには無く、2026-11-05 の収集の下見で新しい行に見つかった**（#308）。
    # ⚠ **`Short Ver.` も短縮版**（`ver` は `version` も拾う）。
    SHORT = /(TV|映画)\s*(サイズ|size)|short\s*(サイズ|size|ver|edit)|(映画|劇場|movie|DX\d*)[^()]*version/i

    def initialize(cure_api: nil)
      @cure_api = cure_api
      @moved = Hash.new(0)
    end

    # 正した `kind`。⚠ **`bgm` と `vocal` のほかは、そのまま返す。**
    def kind(row)
      kind = corrected(row)
      @moved["#{row[:kind]}->#{kind}"] += 1 unless kind == row[:kind]
      return kind
    end

    # ⚠⚠ **歌手の一覧が引けないと、歌手名義の行は黙って `bgm` に残る**（`CV:` 名義だけは
    # 一覧なしで見分けられる）。🔴 **黙らない**（→ `CoverSelector` の #88 と同じ）。
    # ⚠ **書く先は呼ぶ側の logger**（取り込みの警告と同じ所に出す）。
    def report(logger)
      payload = {track: 'soundtrack', moved: @moved.dup}
      return logger.warn(payload.merge(message: 'cure-api is unavailable')) unless available?
      return logger.info(payload)
    end

    def song?(artist_name)
      return true if CHARACTER.match?(normalize(artist_name))
      return cure_api.singer?(artist_name)
    end

    def short?(name)
      return SHORT.match?(normalize(name))
    end

    # ⚠ **歌手の一覧が引けたか**（写しで代われた場合を含む）。⚠⚠ **引けないと歌手名義の行は
    # `bgm` のまま残る**ので、取り込みはこれを見て警告を出す。
    def available?
      return cure_api.available?
    end

    private

    def corrected(row)
      case row[:kind]
      when 'vocal'
        return short?(row[:trackName]) ? 'tv_size' : 'vocal'
      when 'bgm'
        return 'bgm' unless song?(row[:artistName])
        return short?(row[:trackName]) ? 'tv_size' : 'vocal'
      end
      return row[:kind]
    end

    # ⚠ **要るときにだけ作る**（`bgm` でない行では cure-api を引かない）。
    def cure_api
      @cure_api ||= CureApiService.new
      return @cure_api
    end

    def normalize(value)
      return value.to_s.unicode_normalize(:nfkc)
    end
  end
end
