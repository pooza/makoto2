#!/usr/bin/env python3
# MAKOTO の track テーブルに入れる曲を iTunes Search API から集める調査用スクリプト。
#
#   ライブ用 (live)  … 宮本佳那子 / 剣崎真琴 / キュアソード の和集合
#   普段用   (daily) … live + プリキュアソング（アーティスト名かアルバム名に「プリキュア」を含む）
#
# 検索は 1 クエリ 200 件で頭打ちになるため、シリーズ名を種にしてアルバムを集め、
# アルバム単位で曲を引く。シリーズ名は cure-api から REST で取る（rubicure は使わない）。
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

UA = {'User-Agent': 'makoto-track-survey/0.1 (research)'}
CURE_API = 'https://cure-api.precure.ml'
LIVE_KEYWORDS = ['宮本佳那子', '剣崎真琴', 'キュアソード']
SLEEP = 2.0  # iTunes Search API の目安（約 20req/min）に寄せる


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
    return []


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


series = series_titles()
terms = series + ['プリキュア', 'プリキュア 主題歌', 'プリキュア キャラクターアルバム',
                  'プリキュア ボーカルアルバム', 'プリキュア サウンドトラック'] + LIVE_KEYWORDS
print(f'種にする検索語 {len(terms)} 件', flush=True)

# 1. アルバムを集める
albums = {}
for i, term in enumerate(terms, 1):
    found = get('search', term=term, entity='album', limit=200)
    new = 0
    for r in found:
        if r.get('collectionId') and r['collectionId'] not in albums:
            albums[r['collectionId']] = r
            new += 1
    print(f'[{i}/{len(terms)}] {term}: {len(found)} 件（新規 {new} / 累計 {len(albums)}）', flush=True)

# 2. アーティスト経由のアルバム列挙は行わない。
#    167 アーティスト × 各 200 枚を辿ると 4,556 枚（= 4,556 リクエスト）まで膨らみ、
#    しかもコンピレーション経由で無関係な曲を大量に引き込む割に、
#    シリーズ名で集めた分との重複が大半だった。まずはこの 876 枚で足りるかを見る。

# 3. アルバムごとに曲を引く
tracks = {}
for i, cid in enumerate(sorted(albums), 1):
    for s in get('lookup', id=cid, entity='song', limit=200):
        if s.get('wrapperType') == 'track' and s.get('trackId'):
            tracks.setdefault(s['trackId'], s)
    if i % 25 == 0:
        print(f'  アルバム {i}/{len(albums)} … 曲 {len(tracks)}', flush=True)

print(f'\n生の曲 {len(tracks)} 件', flush=True)

live = [t for t in tracks.values() if is_live(t)]
daily = [t for t in tracks.values() if is_live(t) or is_precure(t)]
json.dump(sorted(live, key=lambda t: t.get('releaseDate') or ''),
          open('corpus_live.json', 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
json.dump(sorted(daily, key=lambda t: t.get('releaseDate') or ''),
          open('corpus_daily.json', 'w', encoding='utf-8'), ensure_ascii=False, indent=2)

print(f'ライブ用 {len(live)} 曲（曲名ユニーク {len({t["trackName"] for t in live})}）', flush=True)
print(f'普段用   {len(daily)} 曲（曲名ユニーク {len({t["trackName"] for t in daily})}）', flush=True)
print(f'除外     {len(tracks) - len(daily)} 曲（プリキュア関係でないもの）', flush=True)
