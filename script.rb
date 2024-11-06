#!D:/Ruby3/bin/ruby

begin
  require 'rubygems'
  rescue LoadError
end
require 'sqlite3'           # databse access
require 'timeout'           # interval sleep
require 'pathname'          # pathname/dirname/filename handling
require 'digest'            # hash/contents-id
require 'pp'                # debug output
require 'io/console'        # bufferless console in/out

#-------------------------------------------
# vars
#-------------------------------------------
SUCCESS = 0
FAILURE = 1

SELF_PATH = File.dirname(File.expand_path(__FILE__))
SELF_EXT  = File.extname(__FILE__)
SELF_BASE = File.basename(__FILE__, SELF_EXT)

PATH_MEDIA      = File.join(SELF_PATH, SELF_BASE).encode('UTF-8')
FILNAME_DB      = [SELF_BASE, '.db'].join.encode('UTF-8')
APP_VIEWER      = 'C:/Program Files/IrfanView/cdrzviewer.exe'
INTERVAL_SECOND = 2.55
ENUM_FILES_STEP = 100
ELAPSED_LIMIT   = 100
WHITE_LIST_EXT  = ['zip']
SCORE_RANGE     = 1..10
SCORE_INITIAL   = 2
HISTORY_LIMIT   = 10

PROCESS_IMMEDIATE = 0
PROCESS_BREAK     = 1
PROCESS_SHOW_PREV = 2
PROCESS_SCORE_INC = 3
PROCESS_SCORE_DEC = 4
PROCESS_REMOVE    = 5
PROCESS_TAGEDIT   = 6

FLAG_NORMAL   = 0
FLAG_FLAGGED  = 1
FLAG_NOTFOUND = 2

TAG_TYPE_FILENAME = 0
TAG_TYPE_USER_DEF = 1
TAG_SALT_FILENAME = 'kpwm8oYq'
TAG_SALT_USER_DEF = 'YpN8g6qD'
TAG_SALT_xxx001   = 'XHaQLceS'
TAG_SALT_xxx002   = '0q0byeX1'
TAG_SALT_xxx003   = 'p5CDSHCd'

# view_count    表示回数     (times)
# recent_clock  最終表示時刻 (unixtime)
# elapsed_sec   表示時間総計 (seconds)
# score         スコア       (SCORE_RANGE)
SQL_CREATE_TABLE_CONTENTS   = <<-"EOF_SQL"
CREATE TABLE IF NOT EXISTS "contents" (
  "ids256"        TEXT    NOT NULL  UNIQUE,
  "relpath"       TEXT    NOT NULL  UNIQUE,
  "dir_name"      TEXT    NOT NULL,
  "filename"      TEXT    NOT NULL,
  "view_count"    INTEGER NOT NULL  DEFAULT 0,
  "recent_clock"  INTEGER NOT NULL  DEFAULT 0,
  "elapsed_sec"   INTEGER NOT NULL  DEFAULT 0,
  "score"         INTEGER NOT NULL  DEFAULT #{SCORE_INITIAL},
  "flag"          INTEGER NOT NULL  DEFAULT #{FLAG_NORMAL},
  PRIMARY KEY("ids256")
);
EOF_SQL
SQL_CREATE_TABLE_TAGS   = <<-"EOF_SQL"
CREATE TABLE IF NOT EXISTS "tags" (
  "ids256"    TEXT    NOT NULL  UNIQUE,
  "tag_name"  TEXT    NOT NULL  UNIQUE,
  "tag_type"  INTEGER NOT NULL  DEFAULT #{TAG_TYPE_FILENAME},
  "flag"      INTEGER NOT NULL  DEFAULT #{FLAG_NORMAL},
  PRIMARY KEY("ids256")
);
EOF_SQL
SQL_CREATE_TABLE_CONTENTS_TAGS  = <<-"EOF_SQL"
CREATE TABLE IF NOT EXISTS "contents_tags" (
  "cont_id"   TEXT  NOT NULL,
  "tags_id"   TEXT  NOT NULL,
  PRIMARY KEY("cont_id", "tags_id"),
  CONSTRAINT "fk_cont_id" FOREIGN KEY ("cont_id")
    REFERENCES "contents"("ids256") ON DELETE CASCADE,
  CONSTRAINT "fk_tags_id" FOREIGN KEY ("tags_id")
    REFERENCES "tags"("ids256") ON DELETE CASCADE
);
EOF_SQL

SQL_CONTENTS_CREATE_IDX = 'CREATE INDEX IF NOT EXISTS "idx___COL__" ON "contents" ("__COL__");'
SQL_CONTENTS_UPSERT   = <<-"EOF_SQL"
INSERT INTO "contents" (
  "ids256",
  "relpath",
  "dir_name",
  "filename",
  "flag"
) VALUES (
  :ids256,
  :relpath,
  :dir_name,
  :filename,
  #{FLAG_FLAGGED}
) ON CONFLICT("ids256")
DO UPDATE SET
  "ids256"    = excluded.ids256,
  "relpath"   = :relpath,
  "dir_name"  = :dir_name,
  "filename"  = :filename,
  "flag"      = #{FLAG_FLAGGED};
EOF_SQL
SQL_CONTENTS_UPDATE_REFDATA   = <<-"EOF_SQL"
UPDATE "contents" SET
  "view_count"    = :view_count,
  "recent_clock"  = :recent_clock,
  "elapsed_sec"   = elapsed_sec + :elapsed_sec,
  "score"         = :content_score,
  "flag"          = :flag
WHERE "ids256" = :ids256;
EOF_SQL
SQL_CONTENTS_LIMIT_SCORE_MIN  = <<-"EOF_SQL"
UPDATE "contents" SET
  "score" = :limit
WHERE "score" < :limit;
EOF_SQL
SQL_CONTENTS_LIMIT_SCORE_MAX  = <<-"EOF_SQL"
UPDATE "contents" SET
  "score" = :limit
WHERE "score" > :limit;
EOF_SQL
SQL_CONTENTS_INIT_RECENT_CLOCK  = <<-"EOF_SQL"
UPDATE "contents" SET
  "recent_clock" = :recent_clock
WHERE ("recent_clock" > :recent_clock)
  OR ("recent_clock" = 0);
EOF_SQL
SQL_TAGS_UPSERT   = <<-"EOF_SQL"
INSERT INTO "tags" (
  "ids256",
  "tag_name",
  "tag_type",
  "flag"
) VALUES (
  :ids256,
  :tag_name,
  :tag_type,
  #{FLAG_FLAGGED}
) ON CONFLICT("ids256")
DO UPDATE SET
  "ids256"    = excluded.ids256,
  "tag_name"  = :tag_name,
  "tag_type"  = :tag_type,
  "flag"      = #{FLAG_FLAGGED};
EOF_SQL
SQL_CONTTAGS_UPSERT   = <<-"EOF_SQL"
INSERT INTO "contents_tags" (
  "cont_id",
  "tags_id"
) VALUES (
  :cont_id,
  :tags_id
) ON CONFLICT("cont_id", "tags_id")
DO UPDATE SET
  "cont_id"   = excluded.cont_id,
  "tags_id"   = excluded.tags_id;
EOF_SQL
SQL_TBL_UPDATE_FLAG   = <<-"EOF_SQL"
UPDATE __TBL__ SET
  "flag" = :flag_set
WHERE "flag" = :flag_target;
EOF_SQL

SQL_WITH_CLAUSE   = <<-"EOF_SQL"
WITH
  "t_whole" AS (
    SELECT c.*
    FROM "contents" AS "c"
    WHERE c.flag = #{FLAG_NORMAL})
  ,"v_whole" AS (
    SELECT COUNT(1) AS "count_whole"
      ,MIN(t.score) AS "score_lo_whole"
      ,MAX(t.score) AS "score_hi_whole"
    FROM "t_whole" AS "t")
  ,"v_whole_by_score" AS (
    SELECT t.score AS "score_whole_by_score"
      ,COUNT(1) AS "count_whole_by_score"
      ,MIN(t.view_count) AS "view_count_lo_whole_by_score"
      ,MAX(t.view_count) AS "view_count_hi_whole_by_score"
      -- 同スコア内で MIN(view_count), MAX(view_count) を比較し
      -- 同スコア内の view_count が全て同じ値となった場合
      -- MAX(view_count) + 1 を判断基準値とする
      -- 通常は MAX(t.view_count) そのものを判断基準値とする
      ,(CASE WHEN MIN(t.view_count) = MAX(t.view_count)
        THEN MAX(t.view_count) + 1
        ELSE MAX(t.view_count) END) AS "view_count_bl_whole_by_score"
    FROM "t_whole" AS "t"
    GROUP BY t.score)
  ,"t_vcountflag" AS (
    SELECT t.*
      -- view_count が判断基準値 MAX(view_count) 未満の場合のみ
      -- vcountflag 値として 1 を返す
      ,(CASE WHEN t.view_count < v.view_count_bl_whole_by_score
        THEN #{FLAG_FLAGGED}
        ELSE NULL END) AS "vcountflag"
    FROM "t_whole" AS "t"
      ,"v_whole_by_score" AS "v"
    WHERE t.score = v.score_whole_by_score)
  ,"v_vcountflag_by_score" AS (
    SELECT t.score AS "score_vcountflag_by_score"
      ,COUNT(1) AS "count_vcountflag_by_score"
      ,MIN(t.recent_clock) AS "recent_clock_lo_vcountflag_by_score"
      ,MAX(t.recent_clock) AS "recent_clock_hi_vcountflag_by_score"
      -- 同スコア内で vcountflag 対象の項目で MIN(recent_clock) が
      -- criterion_clock 開始時刻よりも未来寄りの値となった
      -- 場合のみ AVG(recent_clock) を判断基準値とする
      -- 通常は criterion_clock そのものを判断基準値とする
      ,(CASE WHEN MIN(t.recent_clock) >= :criterion_clock
        THEN CAST(AVG(t.recent_clock) AS int)
        ELSE :criterion_clock END) AS "recent_clock_bl_vcountflag_by_score"
    FROM "t_vcountflag" AS "t"
    WHERE t.vcountflag = #{FLAG_FLAGGED}
    GROUP BY t.score)
  ,"t_remainflag" AS (
    SELECT t.*
      -- recent_clock が判断基準値 criterion_clock よりも
      -- 過去寄りの値となった場合のみ remainflag 値として 1 を返す
      ,(CASE WHEN t.recent_clock < v.recent_clock_bl_vcountflag_by_score
        THEN #{FLAG_FLAGGED}
        ELSE NULL END) AS "remainflag"
    FROM "t_vcountflag" AS "t"
      ,"v_vcountflag_by_score" AS "v"
    WHERE t.score = v.score_vcountflag_by_score)
  ,"v_remainflag" AS (
    SELECT COUNT(1) AS "count_total_remainflag"
      ,COUNT(CASE WHEN t.remainflag IS NULL
             THEN 1
             ELSE NULL END) AS "count_leaved_remainflag"
      ,COUNT(CASE WHEN t.remainflag = #{FLAG_FLAGGED}
                   AND t.vcountflag = #{FLAG_FLAGGED}
             THEN 1
             ELSE NULL END) AS "count_remain_remainflag"
    FROM "t_remainflag" AS "t")
  ,"v_remainflag_by_score" AS (
    SELECT t.score AS "score_remainflag_by_score"
      ,COUNT(1) AS "count_total_remainflag_by_score"
      ,COUNT(CASE WHEN t.remainflag IS NULL
             THEN 1
             ELSE NULL END) AS "count_leaved_remainflag_by_score"
      ,COUNT(CASE WHEN t.remainflag = #{FLAG_FLAGGED}
                   AND t.vcountflag = #{FLAG_FLAGGED}
             THEN 1
             ELSE NULL END) AS "count_remain_remainflag_by_score"
    FROM "t_remainflag" AS "t"
    GROUP BY t.score)
  ,"v_sum_by_score" AS (
    SELECT SUM(v.count_total_remainflag_by_score) AS "sum_total_remainflag_by_score"
      ,SUM(v.count_leaved_remainflag_by_score) AS "sum_leaved_remainflag_by_score"
      ,SUM(v.count_remain_remainflag_by_score) AS "sum_remain_remainflag_by_score"
    FROM "v_remainflag_by_score" as "v"
    WHERE v.score_remainflag_by_score
      BETWEEN :score_min
          AND :score_max)
  ,"t_contents" AS (
    SELECT *
    FROM "t_remainflag"
      ,"v_whole"
      ,"v_whole_by_score"
      ,"v_vcountflag_by_score"
      ,"v_remainflag"
      ,"v_remainflag_by_score"
      ,"v_sum_by_score"
    WHERE score = score_whole_by_score
      AND score = score_vcountflag_by_score
      AND score = score_remainflag_by_score)
EOF_SQL

SQL_CONTENTS_GETINFO_VIEWCOUNT = <<-"EOF_SQL"
#{SQL_WITH_CLAUSE}
SELECT v.*
FROM "v_whole_by_score" AS "v"
EOF_SQL

SQL_CONTENTS_RANDOM   = <<-"EOF_SQL"
#{SQL_WITH_CLAUSE}
  ,"t_scored" AS (
    SELECT t.*
    FROM "t_contents" AS "t"
      ,"v_whole" AS "v"
    WHERE t.remainflag = #{FLAG_FLAGGED}
      AND t.vcountflag = #{FLAG_FLAGGED}
      AND t.score
        BETWEEN MAX(v.score_lo_whole, :score_min)
            AND MIN(v.score_hi_whole, :score_max))
  ,"l_scored" AS (
    SELECT t1.score AS "l_score", t1.ids256 AS "l_ids256"
    FROM "t_scored" AS "t1"
    UNION ALL
    SELECT t2.l_score - 1, t2.l_ids256
    FROM "l_scored" AS "t2"
    WHERE t2.l_score > 1
      AND t2.l_ids256 = l_ids256)
  ,"r_scored" AS (
    SELECT l.*
    FROM "l_scored" AS "l"
    LIMIT 1
    OFFSET ABS(RANDOM()) % MAX((
    SELECT COUNT(1) FROM "l_scored"), 1))
SELECT t.*
FROM "t_scored" AS "t"
  ,"r_scored" AS "r"
WHERE t.ids256 = r.l_ids256;
EOF_SQL

SQL_CONTENTS_SPECIFIED  = <<-"EOF_SQL"
#{SQL_WITH_CLAUSE}
SELECT t.*
FROM "t_contents" AS "t"
WHERE t.ids256 = :ids256;
EOF_SQL


#### util-class for console-io ####
module FrUtils
  MODE_CLR_AFTER  = 0
  MODE_CLR_BEFORE = 1
  MODE_CLR_ENTIRE = 2

  class FrUtils::Console
    def con_locate(_x = nil, _y = nil)
      if not _x.nil? then
        # x has specified
        if not _y.nil? then
          # both x,y has specified
          print "\e[#{_y};#{_x}H"
        else
          # only x has specified
          print "\e[#{_x}G"
        end
      elsif not _y.nil? then
        # only y has specified
        print "\e[#{_y}H"
      end
    end

    # _mode
    #   MODE_CLR_AFTER  : カーソルより後ろを消去
    #   MODE_CLR_BEFORE : カーソルより前を消去
    #   MODE_CLR_ENTIRE : 行全体を消去
    def clear_line(_mode = MODE_CLR_ENTIRE)
      con_locate(0, nil) if _mode == MODE_CLR_ENTIRE
      print "\e[#{_mode}K"
    end

    # _mode
    #   MODE_CLR_AFTER  : カーソルより後ろを消去
    #   MODE_CLR_BEFORE : カーソルより前を消去
    #   MODE_CLR_ENTIRE : 画面全体を消去
    def clear_screen(_mode = MODE_CLR_ENTIRE)
      con_locate(0, 0) if _mode == MODE_CLR_ENTIRE
      print "\e[#{_mode}J"
    end
  end
end

class FrRandView
  attr_accessor(:debug_mode)
  attr_accessor(:cons)
  attr_accessor(:history)
  attr_accessor(:history_index)
  attr_accessor(:score_modified)
  attr_accessor(:score_limit_lo)
  attr_accessor(:score_limit_hi)

  def enum_files(_basepath = '', _relpath = '')
    _fullpath = ((_relpath.empty?) ? _basepath : File.join(_basepath, _relpath))
    Dir.foreach(_fullpath) {|_entry|
      next if ['.', '..'].include?(_entry)
      _new = ((_relpath.empty?) ? _entry : File.join(_relpath, _entry))
      if File.directory?(File.join(_fullpath, _entry)) then
        enum_files(_basepath, _new){|_x|
          yield(_x)
        }
      else
        yield(_new)
      end
    }
  end

  def updatedb()
    _listdb = SQLite3::Database.new(File.join(SELF_PATH, FILNAME_DB))
    begin
      _listdb.execute(SQL_CREATE_TABLE_CONTENTS)
      _listdb.execute(SQL_CREATE_TABLE_TAGS)
      _listdb.execute(SQL_CREATE_TABLE_CONTENTS_TAGS)
      ['view_count', 'recent_clock', 'elapsed_sec', 'score', 'flag'].each {|_col|
        _listdb.execute(SQL_CONTENTS_CREATE_IDX.gsub('__COL__', _col))
      }
      ['contents', 'tags'].each {|_tbl|
        _listdb.execute(SQL_TBL_UPDATE_FLAG.gsub('__TBL__', _tbl),
          :flag_set     => FLAG_NORMAL,
          :flag_target  => FLAG_FLAGGED,
        )
        _listdb.execute(SQL_TBL_UPDATE_FLAG.gsub('__TBL__', _tbl),
          :flag_set     => FLAG_NORMAL,
          :flag_target  => FLAG_NOTFOUND,
        )
      }
      _listdb.transaction
      begin
        _cnt = 0
        enum_files(PATH_MEDIA) {|_entry|
          _ext = File.extname(_entry)
          next unless WHITE_LIST_EXT.include?(_ext.delete('.').downcase)
          _ids256 = Digest::SHA256.hexdigest(_entry)
          _dir_name = File.dirname(_entry)
          _filename = File.basename(_entry, _ext)
          _listdb.execute(SQL_CONTENTS_UPSERT,
            :ids256   => _ids256,
            :relpath  => _entry,
            :dir_name => _dir_name,
            :filename => _filename,
          )

          _filename.dup.gsub(/(?<=【)[^【】]+(?=】)/) {|_tagstr|
            _tags256 = Digest::SHA256.hexdigest([TAG_SALT_FILENAME, _tagstr].join)
            _listdb.execute(SQL_TAGS_UPSERT,
              :ids256   => _tags256,
              :tag_name => _tagstr,
              :tag_type => TAG_TYPE_FILENAME,
            )
            _listdb.execute(SQL_CONTTAGS_UPSERT,
              :cont_id  => _ids256,
              :tags_id  => _tags256,
            )
          }
          _cnt = _cnt.succ
          putc '.'  if (_cnt % ENUM_FILES_STEP) == 0
        }
        ['contents', 'tags'].each {|_tbl|
          _listdb.execute(SQL_TBL_UPDATE_FLAG.gsub('__TBL__', _tbl),
            :flag_set     => FLAG_NOTFOUND,
            :flag_target  => FLAG_NORMAL,
          )
          _listdb.execute(SQL_TBL_UPDATE_FLAG.gsub('__TBL__', _tbl),
            :flag_set     => FLAG_NORMAL,
            :flag_target  => FLAG_FLAGGED,
          )
        }
        _listdb.execute(SQL_CONTENTS_LIMIT_SCORE_MIN, :limit => SCORE_RANGE.first)
        _listdb.execute(SQL_CONTENTS_LIMIT_SCORE_MAX, :limit => SCORE_RANGE.last)
        _listdb.execute(SQL_CONTENTS_INIT_RECENT_CLOCK, :recent_clock => Time.now.to_i)
      rescue => e
        _listdb.rollback  if _listdb.transaction_active?
        puts e.message
        puts e.backtrace
      ensure
        _listdb.commit    if _listdb.transaction_active?
      end
      puts ''
    ensure
      _listdb.close
    end
  end

  # 対象項目の情報を表示
  def show_info(_entry = Hash.new())
    @cons.clear_screen  unless @debug_mode
    pp _entry               if @debug_mode

    _range = Range.new(@score_limit_lo, @score_limit_hi).to_s
    _score = _entry['score'].to_s
    _score << ' → ' << @score_modified.to_s  if _entry['score'] != @score_modified

    if @history_index > 0 then
      _view_mode = '直近履歴コンテンツ閲覧: (' << [@history_index, '/', @history.length].join('') << ')'
    else
      _view_mode = 'スコア範囲ランダム閲覧: (' << _range << ')'
    end

    _pad1 = _range.length - _entry['score'].to_s.length - 2
    _pad2 = _range.length - 4

    puts   ''
    puts   (' ' * _pad2) << '      閲覧モード : ' << _view_mode
    puts   (' ' * _pad2) << '      ファイル数 : 閲覧済 / 閲覧対象 / 全体総数'
    printf (' ' * _pad2) << "        全体総数 : %6d : %8d : %8d\n", \
      _entry['count_leaved_remainflag'] + 1, \
      _entry['count_leaved_remainflag'] + _entry['count_remain_remainflag'], \
      _entry['count_whole']
    printf "スコア範囲(%s) : %6d : %8d : %8d\n", \
      _range, \
      _entry['sum_leaved_remainflag_by_score'] + 1, \
      _entry['sum_leaved_remainflag_by_score'] + _entry['sum_remain_remainflag_by_score'], \
      _entry['sum_total_remainflag_by_score']
    printf (' ' * _pad1) << "  個別スコア(%d) : %6d : %8d : %8d\n", \
      _entry['score'], \
      _entry['count_leaved_remainflag_by_score'] + 1, \
      _entry['count_leaved_remainflag_by_score'] + _entry['count_remain_remainflag_by_score'], \
      _entry['count_total_remainflag_by_score']
    puts   (' ' * _pad2) << '元作品タイトル名 : ' << File.basename(File.dirname(_entry['relpath']))
    puts   (' ' * _pad2) << '  コンテンツ書名 : ' << _entry['filename']
    puts   (' ' * _pad2) << '          スコア : ' << _score
    puts   (' ' * _pad2) << '    閲覧回数時間 : ' << [_entry['view_count'], '回', '/', _entry['elapsed_sec'], '秒'].join(' ')
    puts   ''
  end

  def view_rand()
    @cons = FrUtils::Console.new()

    _listdb = SQLite3::Database.new(File.join(SELF_PATH, FILNAME_DB))
    begin
      _listdb.transaction   if @debug_mode
      begin
        _listdb.results_as_hash = true
        begin
          _process_mode     = Array.new()         # 処理の制御情報
          _criterion_clock  = Time.now.to_i - 1   # 表示ループ処理の開始時刻

          # メインループ処理
          loop do
            # 各スコア別の view_count 情報を取得
            _view_count_info = Hash.new()
            _listdb.execute(SQL_CONTENTS_GETINFO_VIEWCOUNT).each {|_entry|
              _view_count_info.store(
                _entry['score_whole_by_score'],
                Range.new(
                  _entry['view_count_lo_whole_by_score'],
                  _entry['view_count_hi_whole_by_score']
                )
              )
            }

            # 次に表示させたい項目の history_index を算出
            if _process_mode.include?(PROCESS_SHOW_PREV) then
              # * １件古い側の項目を指す history_index となる
              # * 既に history の１番古い側の項目を指していた場合は
              #   同じ値のまま変化しない
              # * history が空の場合は 0 となる
              @history_index = [@history_index.succ, @history.length].min
            elsif @history_index > 0 then
              # * １件新しい側の項目を指す history_index となる
              # * 既に history の１番新しい側の項目を指していた場合は 0 となる
              @history_index = [@history_index.pred, 0].max
            end

            # SQL 句に指定するパラメータ情報を格納するハッシュを生成
            _clauses = Hash.new()
            _clauses.store(:criterion_clock,  _criterion_clock)   # 表示ループ処理の開始時刻
            _clauses.store(:score_min,        @score_limit_lo)    # 対象スコア範囲
            _clauses.store(:score_max,        @score_limit_hi)

            if @history_index > 0 then
              # 直近履歴コンテンツ閲覧モード
              _sql = SQL_CONTENTS_SPECIFIED
              # 次に表示させる項目の history_index から ids256 値を特定して指定
              _clauses.store(:ids256, @history[@history_index.pred])
            else
              # スコア範囲ランダム閲覧モード
              _sql = SQL_CONTENTS_RANDOM
            end

            # 処理の制御情報をクリア
            _process_mode.clear

            _listdb.execute(_sql, _clauses).each {|_entry|
              # 対象項目１件毎の処理ループ
              @score_modified = _entry['score']
              _view_count     = _entry['view_count']

              # 直近履歴コンテンツ閲覧モードではない場合のみ
              # 今回表示する項目の ids256 値を history の先頭へ挿入
              unless _clauses.has_key?(:ids256) then
                @history.unshift(_entry['ids256'])
                @history = @history.shift(HISTORY_LIMIT)
              end

              # 今回表示する項目の情報を表示
              show_info(_entry)

              # 表示処理を実行
              _view_start = Time.now.to_i
              system(APP_VIEWER, *[File.join(PATH_MEDIA, _entry['relpath'])])
              _view_end = Time.now.to_i

              # 表示終了後のキー操作をリアルタイムでコンソール処理
              #   echoback-off, unbuffered I/O
              while (print '> '; _input_str = STDIN.getch(min: 0, time: INTERVAL_SECOND, intr: true))
                # 入力文字列を表示用に変換
                _input_print  = _input_str
                _input_byte   = _input_str.unpack('C*').first
                _input_binstr = _input_str.unpack('H*')

                # 入力文字列を処理
                case _input_str
                # 履歴モード・手前ファイル表示へ移行
                when  *["\u002f",       '/',  ] then  # '/'
                  # １件手前に表示していたファイルを再表示させる
                  #   既に history の１番古い側の項目を指していた場合は何もしない
                  if @history_index < @history.length then
                    _process_mode.push(PROCESS_SHOW_PREV)
                    _process_mode.push(PROCESS_IMMEDIATE)
                  end

                # 直近履歴コンテンツ閲覧モードではない場合のみ
                # 表示対象とするスコア範囲を操作
                when  *["\u0056",       'V',          # 'V'
                        "\u0076",       'v',  ] then  # 'v'
                  # 直近履歴コンテンツ閲覧モードではない場合のみ
                  # 表示対象スコア範囲の下限値を -1 する
                  #   既に最小値だった場合は変化しない
                  unless @history_index > 0 then
                    @score_limit_lo = [@score_limit_lo.pred, SCORE_RANGE.first].max
                  end
                when  *["\u0042",       'B',          # 'B'
                        "\u0062",       'b',  ] then  # 'b'
                  # 直近履歴コンテンツ閲覧モードではない場合のみ
                  # 表示対象スコア範囲の下限値を +1 する
                  #   既に最大値だった場合は変化しない
                  unless @history_index > 0 then
                    @score_limit_lo = [@score_limit_lo.succ, SCORE_RANGE.last].min
                    # 表示対象スコア範囲の上限値が下限値を下回った場合
                    # 上限値を下限値と同じ値へ補正する
                    @score_limit_hi = @score_limit_lo   if @score_limit_lo > @score_limit_hi
                  end
                when  *["\u004e",       'N',          # 'N'
                        "\u006e",       'n',  ] then  # 'n'
                  # 直近履歴コンテンツ閲覧モードではない場合のみ
                  # 表示対象スコア範囲の上限値を -1 する
                  #   既に最小値だった場合は変化しない
                  unless @history_index > 0 then
                    @score_limit_hi = [@score_limit_hi.pred, SCORE_RANGE.first].max
                    # 表示対象スコア範囲の下限値が上限値を上回った場合
                    # 下限値を上限値と同じ値へ補正する
                    @score_limit_lo = @score_limit_hi   if @score_limit_lo > @score_limit_hi
                  end
                when  *["\u004d",       'M',          # 'M'
                        "\u006d",       'm',  ] then  # 'm'
                  # 直近履歴コンテンツ閲覧モードではない場合のみ
                  # 表示対象スコア範囲の上限値を +1 する
                  #   既に最大値だった場合は変化しない
                  unless @history_index > 0 then
                    @score_limit_hi = [@score_limit_hi.succ, SCORE_RANGE.last].min
                  end

                # 今回の表示項目のスコア値を操作
                when  *["\u002d",       '-',          # '-'
                        "\u005a",       'Z',          # 'Z'
                        "\u007a",       'z',  ] then  # 'z'
                  # 今回の表示項目のスコアを -1 する
                  # スコアを +1 する際のフラグが残存していたらクリア
                  _process_mode.delete(PROCESS_SCORE_INC)
                  if _process_mode.include?(PROCESS_SCORE_DEC) then
                    # 直前のキー操作で既にスコアが最小値に到達していた場合
                    #   すぐに次ファイルの処理へ移行させる
                    _process_mode.push(PROCESS_IMMEDIATE)
                  end
                  # スコアを -1 する
                  #   既にスコアが最小値だった場合は変化しない
                  @score_modified = [@score_modified.pred, SCORE_RANGE.first].max
                  # 今回操作でスコアが最小値まで到達した場合
                  # フラグを立てておく
                  _process_mode.push(PROCESS_SCORE_DEC)   if @score_modified == SCORE_RANGE.first
                when  *["\u002b",       '+',          # '+'
                        "\u0058",       'X',          # 'X'
                        "\u0078",       'x',  ] then  # 'x'
                  # 今回の表示項目のスコアを +1 する
                  # スコアを -1 する際のフラグが残存していたらクリア
                  _process_mode.delete(PROCESS_SCORE_DEC)
                  if _process_mode.include?(PROCESS_SCORE_INC) then
                    # 直前のキー操作で既にスコアが最大値に到達していた場合
                    #   すぐに次ファイルの処理へ移行させる
                    _process_mode.push(PROCESS_IMMEDIATE)
                  end
                  # スコアを +1 する
                  #   既にスコアが最大値だった場合は変化しない
                  @score_modified = [@score_modified.succ, SCORE_RANGE.last].min
                  # 今回操作でスコアが最大値まで到達した場合
                  # フラグを立てておく
                  _process_mode.push(PROCESS_SCORE_INC)   if @score_modified == SCORE_RANGE.last

                # 今回の表示項目の削除フラグを操作
                when  *["\u0064",       'd',  ] then  # 'd'
                  # 今回の表示項目の削除フラグを指定
                  _process_mode.push(PROCESS_REMOVE)
                when  *["\u0044",       'D',  ] then  # 'D'
                  # 今回の表示項目の削除フラグを指定解除
                  _process_mode.delete(PROCESS_REMOVE)

                # 特殊キー関連
                when  *["\u0020", "\s", ' ',  ] then  # Space
                  # すぐに次ファイルの処理へ移行
                  _process_mode.push(PROCESS_IMMEDIATE)
                  _input_print = '[Space]'
                when  *["\u0003", "\C-c",             # CTRL+C
                        "\u0004", "\C-d",     ] then  # CTRL+D
                  # すぐにメインループ処理を終了
                  _process_mode.push(PROCESS_BREAK)
                when  *["\u001b", "\e",       ] then  # Escape
                  # すぐにメインループ処理を終了
                  _process_mode.push(PROCESS_BREAK)
                  _input_print = '[ESC]'
                when  *["\u000a", "\n",       ] then  # LF Line Feed
                  # カーソルより後ろを消去
                  @cons.clear_line(FrUtils::MODE_CLR_AFTER)
                  _input_print = '[LF]'
                when  *["\u000d", "\r",       ] then  # CR Carriage Return
                  # カーソルより後ろを消去
                  @cons.clear_line(FrUtils::MODE_CLR_AFTER)
                  _input_print = '[CR]'
                when  *["\u0008", "\b",       ] then  # BackSpace
                  # 特に何もしない
                  _input_print = '[BackSpace]'
                when  *["\u007f",             ] then  # Delete
                  # 特に何もしない
                  _input_print = '[Delete]'
                else                                  # Other keys
                  # 特に何もしない
                  if (0x01 .. (?Z.ord - ?A.ord)).cover?(_input_byte) then
                    _input_print = 'Ctrl-' << [_input_byte + 0x40].pack('C*')
                  end
                end

                # 今回表示していた項目の情報を変更値を反映したうえで再表示
                show_info(_entry)

                # 入力された文字列の情報を表示
                puts "Input: #{_input_binstr}, '#{_input_print}'"
                puts ''

                # 制御情報の重複を排除
                _process_mode.uniq!

                # すぐに次ファイルの処理へ移行
                break if _process_mode.include?(PROCESS_IMMEDIATE)
                # すぐにメインループ処理を終了
                break if _process_mode.include?(PROCESS_BREAK)
              end

              # 今回表示していた項目の DB 情報を更新
              _listdb.execute(SQL_CONTENTS_UPDATE_REFDATA,
                :ids256         => _entry['ids256'],
                :recent_clock   => _view_start,
                :content_score  => @score_modified,
                # 表示回数：既存回数に +1 した値を指定
                #   直近履歴コンテンツ閲覧モードだった場合は同じ値のまま
                :view_count     => (_clauses.has_key?(:ids256) ? _entry['view_count'] : _entry['view_count'].succ),
                # 表示時間：今回の表示時間を指定、但し ELAPSED_LIMIT 秒を上限とする
                #   累積値は UPDATE SQL 側で既存値と合算
                :elapsed_sec    => [_view_end - _view_start, ELAPSED_LIMIT].min,
                # 削除フラグ値： FLAG_NORMAL or FLAG_FLAGGED
                :flag           => (_process_mode.include?(PROCESS_REMOVE) ? FLAG_FLAGGED : FLAG_NORMAL),
              )
            }

            # すぐにメインループ処理を終了
            break if _process_mode.include?(PROCESS_BREAK)
          end
        ensure
          _listdb.results_as_hash = false
        end
      rescue => e
        _listdb.rollback  if (_listdb.transaction_active?)
        puts e.message
        puts e.backtrace
      ensure
        _listdb.commit    if (_listdb.transaction_active?)
      end
    ensure
      _listdb.close
    end
  end

  def initialize()
    @debug_mode     = false
    @history        = Array.new()
    @history_index  = 0
    @score_limit_lo = SCORE_RANGE.first
    @score_limit_hi = SCORE_RANGE.last
    @score_modified = SCORE_INITIAL
  end

  def run()
    updatedb()
    view_rand()
  end
end
#-------------------------------------------


#-------------------------------------------
# main
#-------------------------------------------
begin
  _obj = FrRandView.new()
  _obj.run()
rescue => e
  puts e.message
  puts e.backtrace
ensure
  exit 0
end

# end of file
