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

# ライブ本編から外すもの（#63）。
#
# 童謡の仕事は「歌手としての引き出し」なので残すが、**発売日順に並べる以上、
# 同じアルバムの曲は必ず隣接する**ため、そのまま入れると塊で流れる（実測で
# 10 曲 / うち 4 曲が中盤の蝶番の直後に連続した）。アルバム単位で間引く。
#
# 「あそび劇シアター」は劇のアルバムで、オープニング／エンディング／掛け合いは
# 場面の構成物であり、単独で流すと歌ではなく断片に見える。全部落とす。
# 「ショコラちゃんとうたおう」は 1 曲ずつ独立したあそびうたなので 2 曲だけ残す
# （落とす『みんなでいこう!』は 4 名義。MAKOTO は 1 人で歌う → #65 と同じ観点）。
#
# **普段用 (daily) には掛けない。**曲紹介は「紹介」であって「カバーして歌う」
# テイではないので、絞る理由が無い。
LIVE_EXCLUDE_COLLECTIONS = ['あそび劇シアター 3びきのやぎとトロル/さるかにがっせん/ピンポーン']
LIVE_EXCLUDE_TRACKS = ['みんなでいこう![7月]']
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


def is_makoto(track):
    """名義かアルバム名が MAKOTO 本人を指すか。**daily の母集合はこちらを使う。**"""
    joined = norm(track.get('artistName')) + norm(track.get('collectionName'))
    return any(norm(k) in joined for k in LIVE_KEYWORDS)


def is_live_excluded(track):
    """ライブ本編から外すもの（#63）。アルバム単位、または曲単位。"""
    if norm(track.get('collectionName')) in [norm(n) for n in LIVE_EXCLUDE_COLLECTIONS]:
        return True
    return norm(track.get('trackName')) in [norm(n) for n in LIVE_EXCLUDE_TRACKS]


def is_live(track):
    return is_makoto(track) and not is_live_excluded(track)


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
# ⚠ daily は is_makoto。ライブ本編の除外（#63）をここに掛けない。
daily = [t for t in tracks.values() if is_makoto(t) or is_precure(t)]
json.dump(sorted(live, key=lambda t: t.get('releaseDate') or ''),
          open('corpus_live.json', 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
json.dump(sorted(daily, key=lambda t: t.get('releaseDate') or ''),
          open('corpus_daily.json', 'w', encoding='utf-8'), ensure_ascii=False, indent=2)

print(f'ライブ用 {len(live)} 曲（曲名ユニーク {len({t["trackName"] for t in live})}）', flush=True)
print(f'普段用   {len(daily)} 曲（曲名ユニーク {len({t["trackName"] for t in daily})}）', flush=True)
print(f'除外     {len(tracks) - len(daily)} 曲（プリキュア関係でないもの）', flush=True)
