#!/usr/bin/env python3
"""旧 MAKOTO の朝挨拶原稿（`message.type = 'morning'` 237 件）を測る。

原稿を総入れ替えすると二度と測れないので、入れ替える前に「何が『らしさ』を
作っているのか」を数字で残すためのもの（pooza/makoto2#60）。結果は
docs/makoto-legacy.md の「朝挨拶原稿の仕様」に転記する。

    python3 tools/morning_profile.py var/corpus

⚠ **測り方をここに書いておくこと。**過去の計測（makoto-persona.md の
「敬体 41.8%」）は規則が残っていないので再現できない。数字だけを docs に
書くと、次に測った人が違う規則で違う数字を出して、どちらが正しいのか
分からなくなる。

⚠ 入力にはアカウント情報と第三者の著作物（台詞）が含まれる `var/corpus/` を
   使う。**本文は出力しない**（このリポジトリは public）。出すのは件数と
   割合、および旧 DB の id だけ。
"""

import difflib
import hashlib
import json
import re
import statistics
import sys
from collections import Counter
from pathlib import Path

# 文の区切り。⚠ 読点では切らない（「〜けど、〜」で 1 文と数える）。
SENTENCE_SEPARATOR = re.compile(r'[。！？!?\n]+')

# 文末から落とす飾り。絵文字・♪・☆ は語尾ではない。
DECORATION = re.compile(r'[\s。！？!?♪☆…、〜ー]+$|[\U0001F300-\U0001FAFF☀-➿]+$')

# 敬体の語尾。**です / ます の語幹 + 終助詞**という形だけを敬体と数える。
POLITE = re.compile(
  r'(です|ます|でした|ました|ません|ませんでした|ましょう|でしょう|ください|下さい)'
  r'(ね|よ|か|かね|よね)?$',
)

# 常体の語尾。⚠ **「〜だわ」「〜のよ」系の女の子言葉**（本編の register）に加え、
# 終助詞で閉じる形を含める。体言止め・命令形・動詞の終止形は含めない。
PLAIN = re.compile(r'(だわ|わよ|のよ|かしら|だよ|だね|だな|だぞ|だもん|かな|だ|よ|ね|の)$')

# 話題。⚠ **多重ラベル**（1 件が食べ物と季節の両方に当たる）。
#
# 🔴 語彙は 2 段に分かれている（2026-09-05・pooza/makoto2#225）。
#
# - **旧 237 件から拾った語**（#60 の実測に使ったもの。数字の比較のため触らない）
# - ⚠ **`# +2026-09-05` を付けた語** — **#225 で書き足した原稿が使っている語彙**
#
# ⚠⚠ **足した理由**: 🔴 **このリストは旧 237 件を読んで作ったので、新しい原稿の語彙を
# 知らない。**⚠ **「新玉ねぎ」「オムライス」「お味噌汁」「唐揚げ」はどれも食べ物だが
# 1 語も当たらず、「どれにも当たらなかった」に落ちていた**（実測: 325 件中 39 件が
# 未分類で、うち 33 件が #225 で足したもの）。**話題の配分が実際より低く出る。**
#
# 🔴 **したがって足す前の数字と足した後の数字は直接比べられない。**⚠⚠ **旧 237 件も
# 新しいリストで測り直して、両方を docs/makoto-legacy.md に残すこと。**
#
# ## 🔴 語を足すときの規則（2026-09-05・Codex の P2 が 4 件）
#
# ⚠⚠ **判定は `w in body` の部分一致で、形態素解析をしていない。**⚠ **日本語は語の
# 境界が無いので、短い語ほど無関係な文に当たる。**
#
# - 🔴 **日常語に埋もれる断片を入れない** — `だし`（今日は晴れ**だし**）／`たこ`（見
#   **たこと**があります）／`刻ん`（思い出を胸に**刻ん**で）／`合わせ`（力を**合わせ**
#   ましょう）
# - ⚠ **助詞まで含めても足りないことがある** — `風の` は **和風の** / **洋風の** に
#   当たる（**直前が複合語の一部でも通る**）。⚠⚠ **前を見られないので、その語そのものを
#   指す言い方まで書き出す**（`風が吹` / `風の向き` / `そよ風`）
# - ⚠ **同じ綴りで意味が 2 つある語に注意** — `新米`（**米** / **新人**）は `新米を` /
#   `新米が` に絞る
# - 🔴 **足したら旧 237 件を測り直す。**⚠⚠ **リストは旧 237 件から作ったのだから、
#   絞れていれば 1 件も動かないはず** — **動いたら語が広すぎる合図。**
# - ⚠⚠ **害の向きを見る。**🔴 **水増しは「食べ物 4 割に届いている」と読ませる**ので、
#   **足すべき原稿を足さない判断に直結する。**
# - 🔴 **したがって迷ったら落とす。**⚠⚠ **低く出るのは安全側**（**足りないと読めるだけ**）
#   だが、⚠ **高く出るのは危険側。**⚠⚠ **その原稿が未分類のまま残るのは正しい挙動** —
#   **言葉の上で判別できないものを、道具が判別できるふりをしない。**
# ⚠⚠ キーワード照合なので、取りこぼしは「その他」に出る id を読んで足す。
TOPICS = {
  '食べ物・飲み物': [
    'アイス', '白玉', 'ケーキ', 'プリン', 'ラーメン', 'うどん', 'カレー', '焼肉', 'お寿司',
    '寿司', '肉まん', '豚まん', 'パン', 'チョコ', 'ドーナツ', 'イチゴ', 'いちご', 'すいか',
    'スイカ', '梨', '葡萄', '栗', 'きのこ', 'きゅうり', '納豆', '天ぷら', 'しゃぶしゃぶ',
    'つけ麺', 'お好み焼き', 'バーベキュー', 'ポップコーン', 'クレープ', 'ココア', 'コーヒー',
    'ジュース', 'お茶', '餅', 'おにぎり', '弁当', '鍋', '餃子', 'スパゲッティ', '冷やし中華',
    '冷しゃぶ', '生姜焼き', 'ショウガ', 'ドリアン', 'サラダ', 'デザート', 'おやつ', 'ごはん',
    'ご飯', '食べ', '美味しい', 'おいしい', '料理', 'タコ焼き', 'ザリガニ', 'いくら', '海鮮丼',
    'カステラ', 'ラー油', 'ニンニク', 'マヨネーズ', '砂糖', 'ミルク', 'ぜんざい', 'わらび',
    'イカ', '甘いもの',
    # +2026-09-05（#225 で足した原稿の語彙）
    # ⚠⚠ 部分一致なので、日常語に埋もれる断片を入れない（Codex の P2・2026-09-05）。
    #    「だし」は「今日は晴れだし」、「たこ」は「見たことがあります」、
    #    「刻ん」は「思い出を胸に刻んで」に当たる。助詞まで含めて絞るか、落とす。
    # ⚠⚠ 「新米」は入れない。助詞で絞っても「新米を指導します」「新米が入社しました」が
    #    残る（Codex の P2・2 巡）。該当の原稿は `炊け` で当たるので落として構わない。
    '玉ねぎ', 'たまねぎ', 'たけのこ', 'オムライス', '味噌汁', 'みそ汁', 'りんご',
    '唐揚げ', 'たまご焼き', '卵焼き', 'かぼちゃ', 'だしを取', 'だしを引', 'おだし', 'だし汁', '出汁', '昆布', '佃煮',
    # ⚠ 「だしを」は「曲の出だしを」に当たる（Codex の P2）ので、料理の動詞まで含める
    '焼き魚', '煮物', '蕎麦', 'そば湯', '塩を', 'お塩', '果物', 'スープ', 'たこを', 'ゆでだこ',
    # ⚠ 「皮を剥」は「指の皮を剥いて」に当たるので入れない（Codex の P2）
    # ⚠ 「飴」は「飴と鞭」に当たるので入れない（Codex の P2）
    'トースト', 'レモン', '豆腐', 'わかめ', '炊け', '茹で', '火加減', 'ひとつまみ',
  ],
  '歌・仕事': [
    '歌', 'ライブ', 'レコーディング', 'バンド', '稽古', '撮影', 'レッスン', '事務所', '公演',
    '取材', '舞台', 'コンサート', 'リハーサル', 'アルバム', '曲', 'カラオケ', 'ステージ',
    '譜面', 'ギター', '出演', '衣装', 'メイクさん', 'ファンの方', '差し入れ', '収穫祭',
    'プロフィール写真', 'お仕事', '修行', '修業', '音楽', '鼻濁音',
    # +2026-09-05（#225 で足した原稿の語彙）
    # ⚠ 「合わせ」は「力を合わせましょう」に当たるので音楽の文脈まで含める（Codex の P2）。
    #   「喉」も「喉が渇いて」に当たるので絞る。
    # ⚠ 「本番」（受験本番 / 試合本番）と「声出し」（野球部の声出し）は入れない（Codex の P2）
    'マイク', '楽屋', '拍手', '発声', '収録', 'スタジオ', '楽譜', '振り付け',
    '客席', '喉の調子', '喉に手', '歌詞', '調律', '共演', '音合わせ',
  ],
  '天気・季節': [
    '天気', '雨', '雪', '晴れ', '空', '暑い', '寒い', '暖か', '涼し', '春', '夏', '秋', '冬',
    '桜', '紅葉', 'コウヨウ', '梅雨', '台風', '花火', 'セミ', '風鈴', 'クリスマス', 'お正月',
    '干支', 'ハロウィン', '衣替え', '日の出', '夕日', '夕暮れ', '季節', '今日この頃',
    '日が暮れる',
    # +2026-09-05（#225 で足した原稿の語彙）
    # 🔴 「風」は助詞まで含めても足りない（Codex の P2・2026-09-05）。
    #   ⚠⚠ 「風の」は「和風の服」「洋風の料理」に当たる — 直前が複合語の一部でも通る。
    #   ⚠ 部分一致では前を見られないので、風そのものを指す言い方まで含めて書く。
    # ⚠ 「霧」は霧吹き、「雲」は雲泥の差に当たるので、こちらも言い方まで書く（Codex の P2）
    '虹が出', '虹がかかっ', '虹を見', '霧が出', '霧の中', '朝霧', '風が吹', '風がやわ', '風が強', '風がつめた',
    '風が気持ち', '風の向き', '風の音', '風の強', 'そよ風', '向かい風', '曇り空', '曇りの日', '陽が',
    '日差し', '金木犀', '落ち葉', '新緑', '雲が', '雲の形', '雲の切れ間', '雲間', '白い雲',
    '気温', '水たまり',
  ],
  '髪・服・おしゃれ': [
    '髪', '前髪', 'パーマ', 'ストレート', 'カット', '美容室', 'トリートメント', '帽子', '服',
    '靴', 'コート', 'バック', 'おニュー', 'エプロン', 'セーラー服', 'ウェーブ', 'こて',
  ],
  '学校': ['学校', '教室', '通学路', '試験', '宿題', '受験', '中学生', '夏休み', '学生'],
  '星・月・自然': ['星', '月', '流れ星', 'お花', '花', '公園', '海', '山', '温泉', '散歩', '川'],
  '映画・観劇・鑑賞': ['映画', '観劇', 'お芝居', 'ミュージカル', 'DVD', '音楽を聴'],
  '買い物・持ち物': [
    '買い', '買っ', '購入', 'スマホ', '手帳', 'カーペット', '湯呑み', 'ホームセンター',
    'アウトレット', 'レコーダー', '機械', '置物',
  ],
  '感謝・励まし': [
    'ありがとう', '感謝', '幸せ', '素敵', '一期一会', '精進', 'がんばり', '頑張', 'ように',
    '出会い', '出会え', '恩返し', '大事', '大切',
  ],
  '動物': ['ハムスター', 'ウサギ', 'ぶた', 'ハリネズミ', '鯉', 'きつね', 'しろくま', 'ダッフィー'],
  '遊び・スポーツ': [
    '野球', 'ボウリング', 'バッティング', '乗馬', '釣り', 'スキー', 'ゲーム', '岩盤浴',
    'すいか割り', 'スイカ割り', 'お花見', 'いちご狩り', 'イチゴ狩り', '女子会',
  ],
}

# ダジャレ。⚠⚠ **機械では拾えない**ので、237 件を読んで手で拾った id を置く。
# 型は「同音反復」「なんちゃって」「慣用句のズラし」の 3 つ。
PUNS = {
  595780: ('同音反復', 'イカ / イカしてる'),
  595784: ('慣用句のズラし', 'イチゴ屋 / 越後屋'),
  595787: ('同音反復', 'ないよう / 内容'),
  595790: ('同音反復', 'トントロのトン / 豚'),
  595882: ('同音反復', 'ナン / なんじゃこりゃ'),
  595980: ('同音反復', 'ショウガ / しょうがない'),
  596015: ('慣用句のズラし', '目がない / 目が付いてたら'),
  596075: ('なんちゃって', '梨 / ナシ'),
  596080: ('なんちゃって', 'コウヨウ / 見にいコーヨウ'),
  596082: ('なんちゃって', 'コウヨウ / コヌヨウ'),
  596088: ('同音反復', 'いくら / いくらだったか'),
  596101: ('同音反復', '海鮮ドン / ドンまい'),
  596111: ('同音反復', 'ドリアン / どーりやん'),
  596156: ('同音反復', 'ドーナツ / どーなつてるの'),
  596149: ('慣用句のズラし', '滑る / 受験'),
  595935: ('同音反復', '雪やこんこ / コンコン（きつね）'),
}

# ⚠ 時事・固有名詞に縛られていて、いま出すと古い（#60 の取捨選択の軸 1）。
DATED = {
  595775: '原付の免許',
  595955: '新しいスマホ',
  596079: '新しいスマホ',
  596091: 'DVD レコーダー',
  596139: 'ダッフィーくん',
  596156: 'ポンデライオン',
  596020: '食べるラー油',
  596077: '来年の手帳',
  595945: 'カラオケの配信',
  596022: 'コンビニの半熟カステラ',
}

# ⚠ 学生設定（#60 の軸 2・2026-08-14 に「残す」で決着）。真琴自身の学生生活を
# 語っているものだけ。「学生たちは夏休み」のような三人称は含めない。
STUDENT = {595791: '教室の窓', 595942: '通学路の桜', 595947: '学校 / 試験続き',
           595956: '学校の友達', 596075: '宿題'}


def load(directory):
  path = Path(directory) / 'message.json'
  return json.loads(path.read_text(encoding='utf-8'))


def sentences(body):
  return [s for s in SENTENCE_SEPARATOR.split(body) if s.strip()]


def tail(sentence):
  previous = None
  while sentence != previous:
    previous = sentence
    sentence = DECORATION.sub('', sentence)
  return sentence


def register(sentence):
  stripped = tail(sentence)
  if POLITE.search(stripped):
    return '敬体'
  if PLAIN.search(stripped):
    return '常体'
  return 'どちらでもない'


def register_report(label, bodies):
  """register を 3 つの粒度で出す。

  ⚠⚠ **粒度で数字が変わる。**「1 文でも敬体を含む」と「締めが敬体」は別物で、
  過去の計測がどちらだったのかは記録が残っていない。両方出す。
  """
  units = [sentences(b) for b in bodies]
  flat = [register(s) for u in units for s in u]
  last = [register(u[-1]) for u in units]
  contains = sum(1 for u in units if any(register(s) == '敬体' for s in u))
  print(f'\n## register: {label}（原稿 {len(bodies)} 件 / 文 {len(flat)} 文）')
  print('| 粒度 | 敬体 | 常体 | どちらでもない |')
  print('| --- | --- | --- | --- |')
  for name, values in [('文単位', flat), ('締めの文', last)]:
    counter = Counter(values)
    total = len(values)
    cells = ' | '.join(
      f'{counter[k]} ({100 * counter[k] / total:.1f}%)'
      for k in ['敬体', '常体', 'どちらでもない']
    )
    print(f'| {name} | {cells} |')
  print(f'| 1 文でも敬体 | {contains} ({100 * contains / len(bodies):.1f}%) | — | — |')


def length_report(rows):
  lengths = [len(r['message']) for r in rows]
  lines = Counter(r['message'].count('\n') + 1 for r in rows)
  counts = [len(sentences(r['message'])) for r in rows]
  print(f'\n## 長さ（{len(rows)} 件）')
  print(f'- 文字数: 平均 {statistics.mean(lengths):.1f} / 中央 {statistics.median(lengths):.0f} '
        f'/ 最短 {min(lengths)} / 最長 {max(lengths)}')
  print(f'- 文の数: 平均 {statistics.mean(counts):.1f} / 中央 {statistics.median(counts):.0f} '
        f'/ 最多 {max(counts)}')
  print('- 行数: ' + ' / '.join(
    f'{line} 行 {count} 件 ({100 * count / len(rows):.1f}%)' for line, count in sorted(lines.items())
  ))


# 🔴 旧 `morning` 237 件を TOPICS で測った結果（#60 の実測・docs/makoto-legacy.md の表）。
#
# ⚠⚠ **TOPICS はこの 237 件を読んで作ったリスト**なので、⚠ **語を足しても、絞れて
# いればこの数字は 1 件も動かないはず。**🔴 **動いたら、足した語が広すぎて無関係な文に
# 当たっている**（2026-09-05 に実際にそれで気づいた — `だし` が「今日は晴れだし」に
# 当たり、91 → 93 件に増えていた）。
#
# ⚠ **語を足すたびに人が覚えていて突き合わせる、では続かない**ので、⚠⚠ **旧 237 件を
# 測ったときは自動で突き合わせる**（→ `topic_report`）。
BASELINE_237 = {
  '食べ物・飲み物': 91,
  '天気・季節': 80,
  '歌・仕事': 54,
  '星・月・自然': 26,
  '髪・服・おしゃれ': 22,
  '感謝・励まし': 21,
  '買い物・持ち物': 20,
  '遊び・スポーツ': 16,
  '学校': 9,
  '動物': 8,
  '映画・観劇・鑑賞': 8,
}
BASELINE_237_ORPHANS = 7
# ⚠ 旧 237 件の id を昇順に `,` で連結した SHA-256（`595774`〜`596161`）。
#   🔴 件数だけで判定すると、237 行の fixture を旧データと取り違える。
BASELINE_237_DIGEST = '0381f9a4e825479b7c6abcaecbc8d5e99513018f21e50a05204992e148f46e8f'


def is_baseline_corpus(rows):
  """🔴 旧 237 件そのものかを id で見る。

  ⚠⚠ **件数で判定しない**（Codex の P2）。⚠ **fixture や絞り込んだデータが
  たまたま 237 行になると、その差を「語が広すぎる」と誤って鳴らす。**
  """
  ids = ','.join(str(row['id']) for row in sorted(rows, key=lambda r: r['id']))
  return hashlib.sha256(ids.encode()).hexdigest() == BASELINE_237_DIGEST


def baseline_check(rows, hits, orphans):
  """⚠ 旧 237 件を測ったときだけ、#60 の実測と突き合わせる。"""
  if not is_baseline_corpus(rows):
    return
  drift = {
    name: (BASELINE_237.get(name, 0), hits.get(name, 0))
    for name in set(BASELINE_237) | set(hits)
    if BASELINE_237.get(name, 0) != hits.get(name, 0)
  }
  if len(orphans) != BASELINE_237_ORPHANS:
    drift['（どれにも当たらない）'] = (BASELINE_237_ORPHANS, len(orphans))
  if not drift:
    print('\n- ✅ 旧 237 件の実測は #60 と一致（足した語は無関係な文に当たっていない）')
    return
  print('\n- 🔴 **旧 237 件の実測が #60 と食い違う。足した語が広すぎる合図**')
  for name, (expected, actual) in sorted(drift.items()):
    print(f'  - ⚠ {name}: 期待 {expected} / 実測 {actual}')


def topic_report(rows):
  hits = Counter()
  labelled = 0
  orphans = []
  for row in rows:
    body = row['message']
    found = [name for name, words in TOPICS.items() if any(w in body for w in words)]
    hits.update(found)
    if found:
      labelled += 1
    else:
      orphans.append(row['id'])
  print(f'\n## 話題（多重ラベル・{len(rows)} 件中 {labelled} 件が 1 つ以上に当たる）')
  print('| 話題 | 件数 | 割合 |')
  print('| --- | --- | --- |')
  for name, count in hits.most_common():
    print(f'| {name} | {count} | {100 * count / len(rows):.1f}% |')
  print(f'\n- どれにも当たらなかった {len(orphans)} 件: {orphans}')
  baseline_check(rows, hits, orphans)


def pun_report(rows):
  # ⚠⚠ **測った母集合に在る id だけで数える。**手で拾った id の表は固定なので、
  # 取り込み元を絞って走らせると（fixture など）**分母だけが小さくなって
  # 「800%」のような数字が出る**。docs へ写す数字なので、必ず交差を取る。
  ids = {r['id'] for r in rows}
  found = {i: v for i, v in PUNS.items() if i in ids}
  types = Counter(kind for kind, _ in found.values())
  print(f'\n## ダジャレ（手で拾った {len(found)} 件 / {len(rows)} 件中 '
        f'{100 * len(found) / len(rows):.1f}%）')
  print('| 型 | 件数 |')
  print('| --- | --- |')
  for kind, count in types.most_common():
    print(f'| {kind} | {count} |')
  missing = [i for i in PUNS if i not in ids]
  if missing:
    print(f'⚠ この母集合に無い id が {len(missing)} 件（数えていない）: {missing}')


def person_report(rows):
  bodies = [r['message'] for r in rows]
  print(f'\n## 一人称・呼びかけ（{len(rows)} 件）')
  print('| 語 | 件数 |')
  print('| --- | --- |')
  for label, pattern in [
    ('わたし', r'わたし'),
    ('私', r'私'),
    ('真琴（自称）', r'真琴'),
    ('「〜真琴です / でした」で閉じる', r'真琴(です|でした)[。！☆♪…]*$'),
    ('みなさん・皆さん', r'(みなさん|皆さん)'),
    ('みんな', r'みんな'),
  ]:
    count = sum(1 for b in bodies if re.search(pattern, b, re.M))
    print(f'| {label} | {count} |')


def flag_report(rows):
  ids = {r['id'] for r in rows}
  print(f'\n## 取捨選択の軸（{len(rows)} 件）')
  for label, table in [('古びたもの（時事・固有名詞）', DATED), ('学生設定', STUDENT)]:
    listed = {i: v for i, v in table.items() if i in ids}
    print(f'- **{label}**: {len(listed)} 件 — ' + ' / '.join(
      f'{i}（{v}）' for i, v in sorted(listed.items())
    ))


def birthday_report(rows, morning):
  """⚠⚠ **`birthday` 23 件のうち、`morning` の複製でないものが何件か**（#60）。

  🔴 **落としてよいかの判断がここに掛かる。**複製なら `morning` 側に同じ文が
  残るので、落としても失われない。⚠ 「ほぼ同一」は句読点・語尾だけの違いを
  拾うための閾値（`difflib` の比率 0.8 以上）。
  """
  bodies = [r['message'] for r in morning]
  exact, near, unique = 0, [], []
  for row in rows:
    body = row['message']
    best = max(bodies, key=lambda b: difflib.SequenceMatcher(None, body, b).ratio())
    ratio = difflib.SequenceMatcher(None, body, best).ratio()
    if body == best:
      exact += 1
    elif ratio >= 0.8:
      near.append(row['id'])
    else:
      unique.append(row['id'])
  print(f'\n## birthday {len(rows)} 件と morning の重なり')
  print(f'- **本文が完全一致**: {exact} 件')
  print(f'- **ほぼ同一（0.8 以上）**: {len(near)} 件 — {near}')
  print(f'- ✅ **固有**: {len(unique)} 件 — {unique}')


def season_report(rows):
  seasoned = [r for r in rows if r['data']]
  months = Counter()
  for row in seasoned:
    for month in json.loads(row['data']).get('season', []):
      months[month] += 1
  print(f'\n## 季節指定（{len(seasoned)} / {len(rows)} 件）')
  print('- 月ごとの件数: ' + ' / '.join(f'{m}月 {months[m]}' for m in range(1, 13)))


def main(directory):
  rows = load(directory)
  morning = [r for r in rows if r['type'] == 'morning']
  quotes = json.loads((Path(directory) / 'quote.json').read_text(encoding='utf-8'))
  respondable = [q for q in quotes if not q['exclude'] and not q['exclude_respond']]

  print(f'# 朝挨拶原稿の実測（morning {len(morning)} 件）')
  length_report(morning)
  register_report('朝挨拶 morning', [r['message'] for r in morning])
  register_report('本編 quote 全件', [q['body'] for q in quotes])
  register_report('本編 quote 応答可', [q['body'] for q in respondable])
  birthday_report([r for r in rows if r['type'] == 'birthday'], morning)
  topic_report(morning)
  pun_report(morning)
  person_report(morning)
  season_report(morning)
  flag_report(morning)


if __name__ == '__main__':
  main(sys.argv[1] if len(sys.argv) > 1 else 'var/corpus')
