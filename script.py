import time
import sqlite3
import numpy as np
from pathlib import Path
import matplotlib.pyplot as plt
import matplotlib.colors as mcolors
from mpl_toolkits.mplot3d import Axes3D

# ファイル名（拡張子あり）を取得
filename = Path(__file__).name
# ファイル名のみ（拡張子なし）を取得
name_only = Path(__file__).stem

# 自ファイルの絶対パス
current_file = Path(__file__).resolve()
# 自ファイルがあるディレクトリ
current_path = Path(__file__).resolve().parent

# 拡張子情報を変更
new_path = Path(__file__).with_suffix('.db')

sql = '''\
WITH
  "t_whole" AS (
    -- contents に対し flag = FLAG_NORMAL のみ抽出
    -- 同時に１回あたりの平均参照時間を avg_sec として算出
    SELECT c.*
      ,(CASE WHEN c.view_count = 0 THEN 0.0
             ELSE CAST(c.elapsed_sec AS FLOAT) / c.view_count END) AS "avg_sec"
    FROM "contents" AS "c"
    WHERE c.flag = 0)
  ,"v_dat1_score" AS (
    -- t_whole に対し score 単位で
    -- view_count, avg_sec, recent_clock の MIN/MAX 値
    -- recent_clock の基準値を算出
    --   通常は表示ループ処理開始時刻(start_clock) そのものを基準値とし
    --   同スコア内の全件が１度以上閲覧済 = 未来寄りの値の場合のみ
    --   MAX(recent_clock) を基準値とする
    SELECT t.score AS "score_dat1s"
      ,MIN(t.view_count)    AS "min_vc_by_score"
      ,MAX(t.view_count)    AS "max_vc_by_score"
      ,MIN(t.avg_sec)       AS "min_as_by_score"
      ,MAX(t.avg_sec)       AS "max_as_by_score"
      ,MIN(t.recent_clock)  AS "min_rc_by_score"
      ,MAX(t.recent_clock)  AS "max_rc_by_score"
      ,CASE WHEN MIN(t.recent_clock) < :start_clock THEN :start_clock
            ELSE MAX(t.recent_clock) END AS "thr_rc_by_score"
    FROM "t_whole" AS "t"
    GROUP BY t.score)
  ,"v_dat2_all" AS (
    -- t_whole に対し全体対象で score の MIN/MAX 値と Lo/Hi 基準値
    -- 全体の総件数, 閲覧済件数, 閲覧対象残件数を算出
    SELECT COUNT(1) AS "cnt_all_total"
      ,COUNT(CASE WHEN t.recent_clock >= v.thr_rc_by_score THEN 1 ELSE NULL END) "cnt_all_leaved"
      ,COUNT(CASE WHEN t.recent_clock <  v.thr_rc_by_score THEN 1 ELSE NULL END) "cnt_all_remain"
      ,MIN(t.score) AS "min_sc"
      ,MAX(t.score) AS "max_sc"
      ,(CASE WHEN MIN(t.score) > :score_min THEN MIN(t.score)
             WHEN MAX(t.score) < :score_min THEN MAX(t.score)
             ELSE :score_min END) AS "thr_sc_lo"
      ,(CASE WHEN MIN(t.score) > :score_max THEN MIN(t.score)
             WHEN MAX(t.score) < :score_max THEN MAX(t.score)
             ELSE :score_max END) AS "thr_sc_hi"
    FROM "t_whole"      AS "t"
        ,"v_dat1_score" AS "v"
    WHERE t.score = v.score_dat1s)
  ,"v_dat3_score" AS (
    -- t_whole に対し score 単位で総件数, 閲覧済件数, 閲覧対象残件数を算出
    SELECT t.score AS "score_dat3s"
      ,COUNT(1) AS "cnt_by_score_total"
      ,COUNT(CASE WHEN t.recent_clock >= v.thr_rc_by_score THEN 1 ELSE NULL END) AS "cnt_by_score_leaved"
      ,COUNT(CASE WHEN t.recent_clock <  v.thr_rc_by_score THEN 1 ELSE NULL END) AS "cnt_by_score_remain"
    FROM "t_whole"      AS "t"
        ,"v_dat1_score" AS "v"
    WHERE t.score = v.score_dat1s
    GROUP BY t.score)
  ,"v_dat4_specified" AS (
    -- score 単位で算出した件数情報と score の Lo/Hi 基準値から
    -- 閲覧対象の score 範囲のみ対象で総件数, 閲覧済件数, 閲覧対象残件数を算出
    SELECT SUM(b.cnt_by_score_total)  AS "cnt_specified_total"
          ,SUM(b.cnt_by_score_leaved) AS "cnt_specified_leaved"
          ,SUM(b.cnt_by_score_remain) AS "cnt_specified_remain"
    FROM "v_dat2_all"   AS "a"
        ,"v_dat3_score" AS "b"
    WHERE b.score_dat3s BETWEEN a.thr_sc_lo AND a.thr_sc_hi)
  ,"t_contents" AS (
    -- t_whole と各条件毎の基準値, 総件数, 閲覧済件数, 閲覧対象残件数 に関する情報を結合
    SELECT *
    FROM "t_whole"          AS "t" -- 全件               -- contents
        ,"v_dat1_score"     AS "s" -- スコア毎           -- 各 MIN/MAX 値と recent_clock の基準値
        ,"v_dat2_all"       AS "a" -- 全件               -- 総件数, 閲覧済件数, 閲覧対象残件数, score MIN/MAX の基準値
        ,"v_dat3_score"     AS "b" -- スコア毎           -- 総件数, 閲覧済件数, 閲覧対象残件数
        ,"v_dat4_specified" AS "c" -- 閲覧対象スコア範囲 -- 総件数, 閲覧済件数, 閲覧対象残件数
    WHERE t.score = s.score_dat1s
      AND t.score = b.score_dat3s)
  ,"v_dat5_specified" AS (
    -- t_contents を閲覧対象スコア範囲のみに絞り込み
    -- 各行に view_count, avg_sec, recent_clock 基準の相対比較値を付与
    --   view_count   -- 最大値に近づくように MAX との差分を相対値
    --   avg_sec      -- 最大値に近づくように MAX との差分を相対値
    --   recent_clock -- 時間差が大きいほど優先されるように現在時刻からの差分を相対値
    SELECT t.*
      ,ABS(t.max_vc_by_score - t.view_count) AS "cal_vc"
      ,ABS(t.max_as_by_score - t.avg_sec)    AS "cal_as"
      ,ABS(:current_clock - t.recent_clock)  AS "cal_rc"
    FROM "t_contents" AS "t"
    WHERE t.score BETWEEN t.thr_sc_lo AND t.thr_sc_hi)
  ,"v_dat6_rank" AS (
    -- 各行に付与していた view_count, avg_sec, recent_clock の相対比較値から
    -- 各々を基準とした PERCENT_RANK 値を算出
    --   同:view_count   -- 比:avg_sec     -- 比:recent_clock
    --   同:avg_sec      -- 比:view_count  -- 比:recent_clock
    --   同:recent_clock -- 比:view_count  -- 比:avg_sec
    SELECT v.*
      ,PERCENT_RANK() OVER (PARTITION BY v.score ORDER BY v.cal_vc ASC, v.cal_as ASC, v.cal_rc ASC) AS "per_vc"
      ,PERCENT_RANK() OVER (PARTITION BY v.score ORDER BY v.cal_as ASC, v.cal_vc ASC, v.cal_rc ASC) AS "per_as"
      ,PERCENT_RANK() OVER (PARTITION BY v.score ORDER BY v.cal_rc ASC, v.cal_vc ASC, v.cal_as ASC) AS "per_rc"
    FROM "v_dat5_specified" AS "v")
  ,"v_dat7_rank" AS (
    -- 各行に付与していた PERCENT_RANK 値から最も重要視されるべき項目を特定
    SELECT v.*
      ,MAX(v.per_vc, v.per_as, v.per_rc) AS "per_max"
    FROM "v_dat6_rank" AS "v")
  ,"v_dat8_rank" AS (
    -- PERCENT_RANK 基準の重要度から 1-10 の group に分類
    SELECT v.*
      ,NTILE(10) OVER (PARTITION BY v.score ORDER BY v.per_max ASC) AS "per_val"
    FROM "v_dat7_rank" AS "v")
  ,"t_specified" AS (
    -- 各行に付与していた重要度基準の group 値と score 値から weight 値を算出
    --   weight = group + ((score - 1) * 2)
    --     score=1: 1-10, 2: 3-12, 3: 5-14, 4: 7-16,  5: 9-18
    --     score=6:11-20, 7:13-22, 8:15-24, 9:17-26, 10:19-28
    SELECT v.*
      ,(v.per_val + ((v.score - 1) * 2)) AS "weight"
    FROM "v_dat8_rank" AS "v")
  ,"d_specified" AS (
    -- t_specified に対して 各行の weight カラム値に示された回数だけ
    -- ids256 カラム値を繰り返し複製したものを生成
    --   (ids256, weight-1) を返すテーブルと UNION ALL して再帰クエリし
    --   weight 値の数だけ行を複製した ids256 のリストを生成
    SELECT t.ids256 AS "d_ids256"
      ,t.weight AS "d_weight"
    FROM "t_specified" AS "t"
    UNION ALL
    SELECT d.d_ids256
      ,d.d_weight - 1
    FROM "d_specified" AS "d"
    WHERE d.d_weight > 1)
  ,"r_specified" AS (
    -- d_specified からランダムで１件抽出して ids256 値を特定
    SELECT d.*
    FROM "d_specified" AS "d"
    LIMIT 1
    OFFSET ABS(RANDOM()) % MAX((
      SELECT COUNT(1) FROM "d_specified"), 1))
-- t_specified から 3D プロットに欲しい項目を抽出
SELECT t.score as s
  ,t.per_rc as x
  ,t.per_vc as y
  ,t.per_as as z
  ,t.weight as w
FROM t_specified as t
'''

sqlparams = {
  'score_min': 1,
  'score_max': 10,
  'start_clock': int(time.time()),
  'current_clock': int(time.time())
}

conn = sqlite3.connect(new_path)
cursor = conn.cursor()
cursor.execute(sql, sqlparams)
data = cursor.fetchall()
conn.close()

# 3D プロットの作成
fig = plt.figure()
ax = fig.add_subplot(111, projection='3d')

# ラベルの設定
ax.set_xlabel('recent_clock')
ax.set_ylabel('view_count')
ax.set_zlabel('avg_sec')

# score の min/max を取得
scores = [row[0] for row in data]
score_min = min(scores)
score_max = max(scores)

# score 毎に color を決定
c = plt.cm.plasma(np.linspace(0, 0.6, score_max - score_min + 1))

# score min to max loop
for score in range(score_min, score_max + 1):
  # データを x, y, z 軸のリストに分解
  x = [row[1] for row in data if row[0] == score]
  y = [row[2] for row in data if row[0] == score]
  z = [row[3] for row in data if row[0] == score]
  w = [row[4] for row in data if row[0] == score]

  # score 毎に weight の min/max を取得
  w_min = min(w)
  w_max = max(w)
  sizes = np.linspace(1, 50, w_max - w_min + 1)
  cal_w = [sizes[d - w_min] for d in w]

  ax.scatter(x, y, z,
    s=cal_w,
    color=tuple(c[score - 1]),
    marker='*',
    alpha=0.4, label=('score=' + str(score)))

plt.legend()
plt.show()

# end of file
