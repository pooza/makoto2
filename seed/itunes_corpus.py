#!/usr/bin/env python3
# MAKOTO の曲データ（seed/makoto_tracks_daily.json）に、新しいプリキュアソングを足す（pooza/makoto2#294）。
#
#   python3 seed/itunes_corpus.py            # 収集して seed/makoto_tracks_daily.json を更新し、報告を出す
#   python3 seed/itunes_corpus.py --dry-run  # 収集して報告だけ出す（seed/ は書き換えない）
#
# 検索は 1 クエリ 200 件で頭打ちになるため、シリーズ名を種にしてアルバムを集め、
# アルバム単位で曲を引く。シリーズ名は cure-api から REST で取る（rubicure は使わない）。
# ⚠ iTunes Search API を 900 回ほど叩くので 30 分以上かかる（目安 20req/min に寄せている）。
#
# 🔴 既存の行は 1 文字も変えない。足すのは新しく見つかった行だけ（kind は track_kind.py）。
#   ⚠⚠ 普段用には artist 経由で集めた曲（itunes_union.py・宮本佳那子さん本人のアルバム）も
#   入っているので、シリーズ経由の収集だけで作り直すと、それが「消えた」ように見える。
#   ⚠ 収集で見つからなかった既存の行は消さず、報告に「見つからなかった」として出すだけ
#   （配信終了か、シリーズ経由では届かない曲か — 判断は人がする）。
#
# 🔴 ライブ用（seed/makoto_tracks_live.json）には触らない（11/4 まで凍結・#294）。
#   ⚠ ライブ用の行が普段用に 1 行でも欠けると、取り込み（track import）がその曲に
#   live を立てられない — 既存の行を消さないので起きないが、報告で確かめる。
import argparse
import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request

from track_kind import classify

UA = {'User-Agent': 'makoto-track-survey/0.2 (pooza/makoto2)'}
CURE_API = 'https://cure-api.precure.ml'
LIVE_KEYWORDS = ['宮本佳那子', '剣崎真琴', 'キュアソード']
SLEEP = 2.0  # iTunes Search API の目安（約 20req/min）に寄せる
SEED = os.path.dirname(os.path.abspath(__file__))
DAILY = os.path.join(SEED, 'makoto_tracks_daily.json')
LIVE = os.path.join(SEED, 'makoto_tracks_live.json')

# seed/ に持つ項目（iTunes の応答から絞る）。⚠ 並びも seed/ の既存の行に揃える。
FIELDS = ['trackId', 'collectionId', 'trackName', 'artistName', 'collectionName', 'releaseDate',
          'trackTimeMillis', 'trackNumber', 'trackViewUrl', 'previewUrl', 'artworkUrl100']

# 🔴 語りのトラックの候補（pooza/makoto2#298）。⚠ 判定はしない — 人が見て track_spoken.yaml に足す。
SPOKEN_WORDS = re.compile(r'ドラマ|トーク|朗読|語り|ボイス|おしゃべり|もしも')
SPOKEN_MILLIS = 8 * 60 * 1000


def get(path, **params):
    params.setdefault('country', 'jp')
    url = f'https://itunes.apple.com/{path}?' + urllib.parse.urlencode(params)
    for attempt in range(3):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=30) as res:
                body = json.loads(res.read().decode('utf-8'))
            time.sleep(SLEEP)
            return body.get('results', [])
        except (urllib.error.URLError, json.JSONDecodeError, TimeoutError) as e:
            print(f'  ! retry {attempt + 1}: {e}', flush=True)
            time.sleep(5)
    # ⚠ 3 回とも落ちたら止める。黙って空を返すと、そのアルバムの新曲が静かに抜ける。
    raise SystemExit(f'取得できませんでした: {url}')


def norm(text):
    return re.sub(r'[\s！!♪☆♡～~・]', '', text or '')


def is_live(track):
    joined = norm(track.get('artistName')) + norm(track.get('collectionName'))
    return any(norm(k) in joined for k in LIVE_KEYWORDS)


def is_precure(track):
    return 'プリキュア' in norm(track.get('artistName')) + norm(track.get('collectionName')) \
        or 'ぷりきゅあ' in norm(track.get('artistName')) + norm(track.get('collectionName'))


def series_titles():
    """シリーズ名を cure-api から取る。ローカルの作業コピーには依存しない。"""
    req = urllib.request.Request(f'{CURE_API}/series', headers=UA)
    with urllib.request.urlopen(req, timeout=30) as res:
        return [entry['title'].strip() for entry in json.loads(res.read().decode('utf-8'))]


def collect():
    """シリーズ経由でアルバムを集め、プリキュア関係の曲を返す（trackId → 行）。"""
    terms = series_titles() + ['プリキュア', 'プリキュア 主題歌', 'プリキュア キャラクターアルバム',
                               'プリキュア ボーカルアルバム', 'プリキュア サウンドトラック'] + LIVE_KEYWORDS
    print(f'種にする検索語 {len(terms)} 件', flush=True)
    albums = {}
    for i, term in enumerate(terms, 1):
        found = get('search', term=term, entity='album', limit=200)
        new = 0
        for r in found:
            if r.get('collectionId') and r['collectionId'] not in albums:
                albums[r['collectionId']] = r
                new += 1
        print(f'[{i}/{len(terms)}] {term}: {len(found)} 件（新規 {new} / 累計 {len(albums)}）', flush=True)
    # ⚠ アーティスト経由のアルバム列挙は行わない（4,556 枚まで膨らみ、大半が重複だった）。
    tracks = {}
    for i, cid in enumerate(sorted(albums), 1):
        for s in get('lookup', id=cid, entity='song', limit=200):
            if s.get('wrapperType') == 'track' and s.get('trackId'):
                tracks.setdefault(s['trackId'], s)
        if i % 25 == 0:
            print(f'  アルバム {i}/{len(albums)} … 曲 {len(tracks)}', flush=True)
    print(f'生の曲 {len(tracks)} 件', flush=True)
    return {tid: t for tid, t in tracks.items() if is_live(t) or is_precure(t)}


def to_row(track):
    row = {field: track.get(field) for field in FIELDS}
    row['kind'] = classify(track)
    return row


def minutes(millis):
    return f'{(millis or 0) // 60000}:{(millis or 0) // 1000 % 60:02d}'


def report(new_rows, missing, daily, live):
    lines = [f'# 曲データの差分（{time.strftime("%Y-%m-%d")}）', '']
    lines.append(f'- 既存 {len(daily)} 行 / 🔴 新しく見つかった {len(new_rows)} 行 / ⚠ 見つからなかった既存 {len(missing)} 行')
    by_kind = {}
    for row in new_rows:
        by_kind[row['kind']] = by_kind.get(row['kind'], 0) + 1
    lines.append(f'- 新しい行の kind: {by_kind}')
    ids = {row['trackId'] for row in daily} | {row['trackId'] for row in new_rows}
    absent = [row for row in live if row['trackId'] not in ids]
    lines.append(f'- ライブ用が普段用に揃っているか: {"✅" if not absent else f"🔴 {len(absent)} 行が欠けている"}')
    lines += ['', '## 🔴 新しく見つかった行（kind を目で確かめる）', '']
    for row in sorted(new_rows, key=lambda r: (r.get('releaseDate') or '', r.get('trackName') or '')):
        lines.append(f'- `{row["kind"]}` {row["trackName"]} / {row["artistName"]} / '
                     f'{row["collectionName"]}（{(row.get("releaseDate") or "")[:10]}・{minutes(row.get("trackTimeMillis"))}）')
    spoken = [row for row in new_rows if row['kind'] == 'vocal' and
              (SPOKEN_WORDS.search(row['trackName'] or '') or (row.get('trackTimeMillis') or 0) >= SPOKEN_MILLIS)]
    lines += ['', '## ⚠ 語りのトラックの候補（#298 — 人が見て seed/track_spoken.yaml に足す）', '']
    lines += [f'- {row["trackName"]}（{minutes(row.get("trackTimeMillis"))}）' for row in spoken] or ['- 無し']
    lines += ['', '## ⚠ 見つからなかった既存の行（消していない — 配信終了か、シリーズ経由で届かない曲）', '']
    lines += [f'- {row["trackName"]} / {row["artistName"]}' for row in missing[:200]] or ['- 無し']
    if len(missing) > 200:
        lines.append(f'- …ほか {len(missing) - 200} 行')
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description="seed/makoto_tracks_daily.json に新しいプリキュアソングを足す（#294）")
    parser.add_argument('--dry-run', action='store_true', help='seed/ を書き換えず、報告だけ出す')
    parser.add_argument('--report', default='track_report.md', help='報告の出力先（既定はカレントの track_report.md）')
    parser.add_argument('--out', default=DAILY, help='足した結果の書き出し先（既定は seed/makoto_tracks_daily.json）。⚠ 下見のために別の場所へ書くとき')
    args = parser.parse_args()

    daily = json.load(open(DAILY, encoding='utf-8'))
    live = json.load(open(LIVE, encoding='utf-8'))
    known = {row['trackId'] for row in daily}
    found = collect()
    new_rows = [to_row(t) for tid, t in found.items() if tid not in known]
    missing = [row for row in daily if row['trackId'] not in found]

    with open(args.report, 'w', encoding='utf-8') as f:
        f.write(report(new_rows, missing, daily, live))
    print(f'新しい行 {len(new_rows)} / 見つからなかった既存 {len(missing)} → {args.report}', flush=True)
    if args.dry_run or not new_rows:
        return
    rows = sorted(daily + new_rows, key=lambda t: t.get('releaseDate') or '')
    with open(args.out, 'w', encoding='utf-8') as f:
        # ⚠ 末尾に改行を足さない（既存のファイルが持っていないので、差分が全行に広がる）。
        json.dump(rows, f, ensure_ascii=False, indent=2)
    print(f'→ {args.out}（{len(daily)} → {len(rows)} 行）', flush=True)


if __name__ == '__main__':
    main()
