#!/usr/bin/env python3
"""MAKOTO の曲データ（seed/makoto_tracks_daily.json）に、新しいプリキュアソングを足す（pooza/makoto2#294）。

    python3 seed/itunes_corpus.py            # 収集して seed/makoto_tracks_daily.json を更新し、報告を出す
    python3 seed/itunes_corpus.py --dry-run  # 収集して報告だけ出す（seed/ は書き換えない）

検索は 1 クエリ 200 件で頭打ちになるため、シリーズ名を種にしてアルバムを集め、
アルバム単位で曲を引く。シリーズ名は cure-api から REST で取る（rubicure は使わない）。
⚠ iTunes Search API を 900 回ほど叩くので 45 分ほどかかる（1 分あたり 20 回に寄せている → `SLEEP`）。

🔴 既存の行は 1 文字も変えない。足すのは新しく見つかった行だけ（kind は track_kind.py）。
  ⚠⚠ 普段用には artist 経由で集めた曲（itunes_union.py・宮本佳那子さん本人のアルバム）も
  入っているので、シリーズ経由の収集だけで作り直すと、それが「消えた」ように見える。
  ⚠ 収集で見つからなかった既存の行は消さず、報告に「見つからなかった」として出すだけ
  （配信終了か、シリーズ経由では届かない曲か — 判断は人がする）。

🔴 ライブ用（seed/makoto_tracks_live.json）には触らない（11/4 まで凍結・#294）。
  ⚠ ライブ用の行が普段用に 1 行でも欠けると、取り込み（track import）がその曲に
  live を立てられない — 既存の行を消さないので起きないが、報告で確かめる。

🔴 報告は「どこまで集めたか」も書く（#316）。⚠⚠ 報告が「新しく見つかった行」しか出さないと、
  「見つからなかった新曲」は誰にも見えない — 検索語ごとの件数・200 件の頭打ち・アルバム数を残す。
  ⚠ 途中で止まったときも報告を書き直す（前回の報告が残ると、同じ日の再実行と見分けられない）。
"""

import argparse
import datetime
import email.utils
import http.client
import json
import math
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request

from track_kind import classify

UA = {'User-Agent': 'makoto-track-survey/0.3 (pooza/makoto2)'}
CURE_API = 'https://cure-api.precure.ml'
LIVE_KEYWORDS = ['宮本佳那子', '剣崎真琴', 'キュアソード']

# ⚠ 1 回ごとの待ち。iTunes Search API の目安（1 分あたり 20 回）に寄せる。
#   ⚠⚠ 2.0 秒のときは応答の時間を足しても 1 分あたり 26〜30 回で、目安を超えていた（#316）。
SLEEP = 3.0

# ⚠ 検索 1 回で返る上限。🔴 ちょうどこの件数なら打ち切られている（201 位以降が沈む）。
SEARCH_LIMIT = 200

# ⚠ 発売日を比べる「いま」の暦（→ `released`）。日本のストア（`country=jp`）なので JST。
JST = datetime.timezone(datetime.timedelta(hours=9))

SEED = os.path.dirname(os.path.abspath(__file__))
DAILY = os.path.join(SEED, 'makoto_tracks_daily.json')
LIVE = os.path.join(SEED, 'makoto_tracks_live.json')

# seed/ に持つ項目（iTunes の応答から絞る）。⚠ 並びも seed/ の既存の行に揃える。
FIELDS = [
  'trackId', 'collectionId', 'trackName', 'artistName', 'collectionName', 'releaseDate',
  'trackTimeMillis', 'trackNumber', 'trackViewUrl', 'previewUrl', 'artworkUrl100',
]

# ⚠ 打ち切られて当然の広い検索語（docs/track-corpus.md「収集の要点」）。🔴 だからシリーズ名を種にしている。
#   ⚠ ここに入れた語が打ち切られても 🔴 にはしない（毎月出るので、出ても誰も読まなくなる）。
BROAD_TERMS = ['プリキュア']

# シリーズ名に足す検索語。
EXTRA_TERMS = [
  'プリキュア', 'プリキュア 主題歌', 'プリキュア キャラクターアルバム',
  'プリキュア ボーカルアルバム', 'プリキュア サウンドトラック',
]

# 🔴 語りのトラックの候補（pooza/makoto2#298）。⚠ 判定はしない — 人が見て track_spoken.yaml に足す。
SPOKEN_WORDS = re.compile(r'ドラマ|トーク|朗読|語り|ボイス|おしゃべり|もしも')
SPOKEN_MILLIS = 8 * 60 * 1000

# 🔴 再試行する失敗（#316）。⚠⚠ `URLError` に包まれるのは要求の失敗だけで、読み込み中の
#   `RemoteDisconnected` / `IncompleteRead`（`http.client.HTTPException`）と `ConnectionResetError`
#   （`OSError`）は素の例外のまま抜けていた。⚠ `TimeoutError` と `URLError` も `OSError` の仲間。
RETRYABLE = (OSError, http.client.HTTPException, json.JSONDecodeError)

# ⚠ iTunes の制限（403 / 429）。解けるまで数十秒かかるので、5 秒おきに 3 回では同じ制限に当たって諦める（#483）。
#   ⚠ `Retry-After` があればそちらに従う（長すぎる値は `THROTTLE_MAX_WAIT` で切る）。
THROTTLED = (403, 429)
THROTTLE_WAIT = 60
THROTTLE_MAX_WAIT = 300
ATTEMPTS = 3


class Progress:
  """どこまで集めたか（#316）。⚠ 途中で止まっても、ここまでの分を報告に書く。"""

  def __init__(self):
    self.started = datetime.datetime.now().astimezone()
    self.series = 0
    self.terms = []  # (検索語, 件数, 新規のアルバム数)
    self.albums = 0
    self.albums_done = 0
    self.raw_tracks = 0

  def capped(self):
    return [term for term, count, _ in self.terms if count >= SEARCH_LIMIT]

  def unexpectedly_capped(self):
    return [term for term in self.capped() if term not in BROAD_TERMS]


def fetch(url):
  """GET して JSON を返す。⚠ 3 回とも落ちたら止める（黙って空を返すと、新曲が静かに抜ける）。"""
  for attempt in range(ATTEMPTS):
    last = attempt == ATTEMPTS - 1
    try:
      with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=30) as res:
        body = json.loads(res.read().decode('utf-8'))
      time.sleep(SLEEP)
      return body
    # ⚠ `HTTPError` は `OSError` の子なので、`RETRYABLE` より先に受ける。
    except urllib.error.HTTPError as e:
      if e.code in THROTTLED:
        wait = retry_after(e)
      elif 400 <= e.code < 500:
        # ⚠ それ以外の 4xx は何度叩いても同じ答え。待たずに止める。
        raise SystemExit(f'取得できませんでした（{e.code}・再試行しない）: {url}')
      else:
        wait = 5
      print(f'  ! retry {attempt + 1}: {e!r}' + ('' if last else f'（{wait} 秒待つ）'), flush=True)
    except RETRYABLE as e:
      wait = 5
      print(f'  ! retry {attempt + 1}: {e!r}', flush=True)
    # ⚠ 最後の試行の後は待たない。次が無いのに最大 THROTTLE_MAX_WAIT 止まってから落ちる（PR #490 の Codex の P2）。
    if not last:
      time.sleep(wait)
  raise SystemExit(f'取得できませんでした: {url}')


def retry_after(error):
  """制限が解けるまでの待ち（秒）。⚠ `Retry-After` が無いか読めなければ `THROTTLE_WAIT`。

  ⚠ 秒数と HTTP-date の両方の形がある（RFC 9110）。日付の形を読めずに 60 秒へ倒すと、
  制限がそれより長いときに 3 回とも当たって諦める（PR #490 の Codex の P2）。
  """
  value = (error.headers.get('Retry-After') or '').strip()
  try:
    seconds = int(value)
  except ValueError:
    try:
      until = email.utils.parsedate_to_datetime(value)
    except (TypeError, ValueError):
      return THROTTLE_WAIT
    if until.tzinfo is None:
      until = until.replace(tzinfo=datetime.timezone.utc)
    seconds = math.ceil((until - datetime.datetime.now(datetime.timezone.utc)).total_seconds())
  return min(max(seconds, 1), THROTTLE_MAX_WAIT)


def get(path, **params):
  params.setdefault('country', 'jp')
  url = f'https://itunes.apple.com/{path}?' + urllib.parse.urlencode(params)
  return fetch(url).get('results', [])


def norm(text):
  return re.sub(r'[\s！!♪☆♡～~・]', '', text or '')


def is_live(track):
  joined = norm(track.get('artistName')) + norm(track.get('collectionName'))
  return any(norm(k) in joined for k in LIVE_KEYWORDS)


def is_precure(track):
  joined = norm(track.get('artistName')) + norm(track.get('collectionName'))
  return 'プリキュア' in joined or 'ぷりきゅあ' in joined


def series_titles():
  """シリーズ名を cure-api から取る。ローカルの作業コピーには依存しない。

  ⚠ 再試行する（#316）。⚠ `title` が空の行は飛ばす（`.strip()` で落ちていた）。
  """
  entries = fetch(f'{CURE_API}/series')
  return [entry['title'].strip() for entry in entries if (entry.get('title') or '').strip()]


def collect(progress):
  """シリーズ経由でアルバムを集め、プリキュア関係の曲を返す（trackId → 行）。"""
  titles = series_titles()
  progress.series = len(titles)
  terms = titles + EXTRA_TERMS + LIVE_KEYWORDS
  print(f'種にする検索語 {len(terms)} 件', flush=True)
  albums = {}
  for i, term in enumerate(terms, 1):
    found = get('search', term=term, entity='album', limit=SEARCH_LIMIT)
    new = 0
    for r in found:
      if r.get('collectionId') and r['collectionId'] not in albums:
        albums[r['collectionId']] = r
        new += 1
    progress.terms.append((term, len(found), new))
    progress.albums = len(albums)
    mark = ' 🔴 上限で打ち切り' if len(found) >= SEARCH_LIMIT else ''
    print(f'[{i}/{len(terms)}] {term}: {len(found)} 件（新規 {new} / 累計 {len(albums)}）{mark}', flush=True)
  # ⚠ アーティスト経由のアルバム列挙は行わない（4,556 枚まで膨らみ、大半が重複だった）。
  tracks = {}
  for i, cid in enumerate(sorted(albums), 1):
    for s in get('lookup', id=cid, entity='song', limit=SEARCH_LIMIT):
      if s.get('wrapperType') == 'track' and s.get('trackId'):
        tracks.setdefault(s['trackId'], s)
    progress.albums_done = i
    progress.raw_tracks = len(tracks)
    if i % 25 == 0:
      print(f'  アルバム {i}/{len(albums)} … 曲 {len(tracks)}', flush=True)
  print(f'生の曲 {len(tracks)} 件', flush=True)
  return {tid: t for tid, t in tracks.items() if is_live(t) or is_precure(t)}


def to_row(track):
  row = {field: track.get(field) for field in FIELDS}
  row['kind'] = classify(track)
  return row


def released(row, now):
  """発売済みか（#316）。⚠ 日付の無い行・読めない行は発売済みとして扱う（既存の行と同じ）。

  🔴 `releaseDate` の日付の部分を、いまを JST に直した日付と比べる（v0.8.0 のリリース前レビュー）。
  ⚠⚠ iTunes の `releaseDate` は発売日の太平洋時間 0 時（`2026-01-28T08:00:00Z` ＝ JST の発売当日 17 時・
  実測）で、日付の部分が日本の発売日と同じ。🔴 時刻で比べると（PR #474 で入れた形）、発売当日の
  0〜17 時 JST に当日の盤を「発売前」として見送っていた。⚠ ホストの TZ にもよらない（UTC のホストでも同じ）。
  """
  # ⚠ 暦として読めない値（`2026-99-99`）も発売済みとして扱う（PR #482 の Codex の P2 — 文字列の比較だと
  #   未来と読んで永久に見送っていた）。
  try:
    date = datetime.date.fromisoformat((row.get('releaseDate') or '')[:10])
  except ValueError:
    return True
  return date <= now.astimezone(JST).date()


def minutes(millis):
  return f'{(millis or 0) // 60000}:{(millis or 0) // 1000 % 60:02d}'


def track_line(row):
  return (
    f'- `{row["kind"]}` {row["trackName"]} / {row["artistName"]} / '
    f'{row["collectionName"]}（{(row.get("releaseDate") or "")[:10]}・{minutes(row.get("trackTimeMillis"))}）'
  )


def header(progress, dry_run, failure=None):
  """報告の見出しと「どこまで集めたか」（#316）。"""
  state = f'🔴 途中で止まった: {failure}' if failure else ('下見（--dry-run）' if dry_run else '反映')
  lines = [f'# 曲データの差分（{progress.started:%Y-%m-%d %H:%M %z}・{state}）', '']
  lines += ['## どこまで集めたか', '']
  lines.append(f'- cure-api のシリーズ {progress.series} 件 / 検索語 {len(progress.terms)} 件 / '
    f'アルバム {progress.albums_done}/{progress.albums} 枚 / 生の曲 {progress.raw_tracks} 件')
  unexpected = progress.unexpectedly_capped()
  if unexpected:
    # 🔴 打ち切られた検索語は、201 位以降のアルバムを取りこぼしている（関連度順）。
    lines.append(f'- 🔴 検索が上限（{SEARCH_LIMIT} 件）で打ち切られた: {" / ".join(unexpected)}')
    lines.append('  ⚠ 201 位以降のアルバム（新シリーズ・シリーズ名を含まないコンピ盤）が沈みうる')
  else:
    lines.append(f'- ✅ シリーズ名などの検索語は上限（{SEARCH_LIMIT} 件）に達していない')
  expected = [term for term in progress.capped() if term in BROAD_TERMS]
  if expected:
    lines.append(f'- ⚠ 広い検索語は想定どおり打ち切られた（シリーズ名で補っている）: {" / ".join(expected)}')
  lines += ['', '<details><summary>検索語ごとの件数</summary>', '']
  lines += [f'- {term}: {count} 件（新規のアルバム {new}）' for term, count, new in progress.terms]
  lines += ['', '</details>', '']
  return lines


def report(progress, dry_run, new_rows, upcoming, missing, daily, live):
  lines = header(progress, dry_run)
  lines += ['## 差分', '']
  lines.append(f'- 既存 {len(daily)} 行 / 🔴 新しく見つかった {len(new_rows)} 行 / '
    f'⚠ 発売前で見送った {len(upcoming)} 行 / ⚠ 見つからなかった既存 {len(missing)} 行')
  by_kind = {}
  for row in new_rows:
    by_kind[row['kind']] = by_kind.get(row['kind'], 0) + 1
  lines.append(f'- 新しい行の kind: {by_kind}')
  ids = {row['trackId'] for row in daily} | {row['trackId'] for row in new_rows}
  absent = [row for row in live if row['trackId'] not in ids]
  lines.append(f'- ライブ用が普段用に揃っているか: {"✅" if not absent else f"🔴 {len(absent)} 行が欠けている"}')
  lines += ['', '## 🔴 新しく見つかった行（kind を目で確かめる）', '']
  lines += [track_line(row) for row in sorted(new_rows, key=sort_key)] or ['- 無し']
  # 🔴 発売前の予約盤は足さない（#316）。⚠⚠ MAKOTO がまだ聴けない曲をリンクつきで紹介してしまう。
  #   ⚠ 発売後の収集で「新しく見つかった行」に出る。
  lines += ['', '## ⚠ 発売前で見送った行（次の収集で足す）', '']
  lines += [track_line(row) for row in sorted(upcoming, key=sort_key)] or ['- 無し']
  spoken = [
    row for row in new_rows
    if row['kind'] == 'vocal'
    and (SPOKEN_WORDS.search(row['trackName'] or '') or (row.get('trackTimeMillis') or 0) >= SPOKEN_MILLIS)
  ]
  lines += ['', '## ⚠ 語りのトラックの候補（#298 — 人が見て seed/track_spoken.yaml に足す）', '']
  lines += [f'- {row["trackName"]}（{minutes(row.get("trackTimeMillis"))}）' for row in spoken] or ['- 無し']
  lines += ['', '## ⚠ 見つからなかった既存の行（消していない — 配信終了か、シリーズ経由で届かない曲）', '']
  lines += [f'- {row["trackName"]} / {row["artistName"]}' for row in missing[:200]] or ['- 無し']
  if len(missing) > 200:
    lines.append(f'- …ほか {len(missing) - 200} 行')
  return '\n'.join(lines) + '\n'


def sort_key(row):
  return (row.get('releaseDate') or '', row.get('trackName') or '')


def load(path):
  with open(path, encoding='utf-8') as f:
    return json.load(f)


def write(path, text):
  with open(path, 'w', encoding='utf-8') as f:
    f.write(text)


def main():
  parser = argparse.ArgumentParser(description='seed/makoto_tracks_daily.json に新しいプリキュアソングを足す（#294）')
  parser.add_argument('--dry-run', action='store_true', help='seed/ を書き換えず、報告だけ出す')
  parser.add_argument('--report', default='track_report.md', help='報告の出力先（既定はカレントの track_report.md）')
  parser.add_argument(
    '--out', default=DAILY,
    help='足した結果の書き出し先（既定は seed/makoto_tracks_daily.json）。⚠ 下見のために別の場所へ書くとき',
  )
  args = parser.parse_args()

  daily = load(DAILY)
  live = load(LIVE)
  known = {row['trackId'] for row in daily}
  progress = Progress()
  try:
    found = collect(progress)
  except BaseException as e:
    # ⚠ データは書かない（正しい）が、報告は書き直す（#316）— 前回の報告が残ると取り違える。
    # 🔴 **どの例外でも**（v0.8.0 のリリース前レビュー）。⚠⚠ cure-api が配列でない JSON を返すと
    #   `AttributeError` で抜け、前回の報告が残っていた。
    write(args.report, '\n'.join(header(progress, args.dry_run, failure=str(e) or type(e).__name__)) + '\n')
    raise
  rows = [to_row(t) for tid, t in found.items() if tid not in known]
  new_rows = [row for row in rows if released(row, progress.started)]
  upcoming = [row for row in rows if not released(row, progress.started)]
  missing = [row for row in daily if row['trackId'] not in found]

  # 🔴 書き出しが済んでから「反映」の報告を書く（PR #474 の Codex の P2）。⚠⚠ 先に書くと、書き出しが
  #   落ちたとき（`--out` の置き場所が無い・ディスクが満杯・中断）に「反映」と読める報告だけが残る。
  if not args.dry_run and new_rows:
    merged = sorted(daily + new_rows, key=lambda t: t.get('releaseDate') or '')
    # 🔴 一時ファイルに書いてから差し替える（v0.8.0 のリリース前レビュー）。⚠⚠ 直に書くと、途中で落ちた
    #   ときに seed/ が切り詰めた半端な中身で残っていた（git から戻せるが、報告はそれを言わなかった）。
    temp = f'{args.out}.tmp'
    try:
      with open(temp, 'w', encoding='utf-8') as f:
        # ⚠ 末尾に改行を足さない（既存のファイルが持っていないので、差分が全行に広がる）。
        json.dump(merged, f, ensure_ascii=False, indent=2)
      os.replace(temp, args.out)
    except BaseException as e:
      if os.path.exists(temp):
        os.remove(temp)
      failure = f'{args.out} へ書き出せなかった（元のファイルはそのまま）: {e!r}'
      write(args.report, '\n'.join(header(progress, args.dry_run, failure=failure)) + '\n')
      raise
    print(f'→ {args.out}（{len(daily)} → {len(merged)} 行）', flush=True)
  write(args.report, report(progress, args.dry_run, new_rows, upcoming, missing, daily, live))
  print(f'新しい行 {len(new_rows)} / 発売前 {len(upcoming)} / 見つからなかった既存 {len(missing)} → {args.report}',
    flush=True)


if __name__ == '__main__':
  main()
