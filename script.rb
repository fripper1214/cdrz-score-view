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
PROCESS_SHOW_NEXT = 2
PROCESS_SHOW_PREV = 3
PROCESS_SCORE_INC = 4
PROCESS_SCORE_DEC = 5
PROCESS_REMOVE    = 6
PROCESS_TAGEDIT   = 7

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

# view_count      表示回数     (times)
# recent_clock    最終表示時刻 (unixtime)
# elapsed_sec     表示時間総計 (seconds)
# score           スコア       (1..10)
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
  "cont_id"   TEXT    NOT NULL,
  "tags_id"   TEXT    NOT NULL,
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

SQL_WITH_CLAUSE     = <<-"EOF_SQL"
WITH
  "t_whole" AS (
    SELECT c.*
    FROM "contents" AS "c"
    WHERE c.flag = #{FLAG_NORMAL})
  ,"v_whole" AS (
    SELECT COUNT(1) AS "cnt_whole"
      ,MIN(t.score) AS "lscore_whole"
      ,MAX(t.score) AS "hscore_whole"
    FROM "t_whole" AS "t")
  ,"v_whole_by_score" AS (
    SELECT t.score AS "score_whole_by_score"
      ,COUNT(1) AS "cnt_whole_by_score"
      ,MIN(t.view_count) AS "lvc_by_score"
      ,MAX(t.view_count) AS "hvc_by_score"
      ,(CASE WHEN MIN(t.view_count) = MAX(t.view_count)
        THEN MAX(t.view_count) + 1
        ELSE MAX(t.view_count) END) AS "bvc_by_score"
    FROM "t_whole" AS "t"
    GROUP BY t.score)
  ,"t_vcflag" AS (
    SELECT t.*
      ,(CASE WHEN t.view_count < v.bvc_by_score
        THEN 1 ELSE NULL END) AS "vcflag"
    FROM "t_whole" AS "t", "v_whole_by_score" AS "v"
    WHERE t.score = v.score_whole_by_score)
  ,"v_vcflag_by_score" AS (
    SELECT t.score AS "score_vcflag_by_score"
      ,COUNT(1) AS "cnt_vcflag_by_score"
      ,MIN(t.recent_clock) AS "lclk_vcflag_by_score"
      ,MAX(t.recent_clock) AS "hclk_vcflag_by_score"
      ,(CASE WHEN MIN(t.recent_clock) > :criterion_clock
        THEN MAX(t.recent_clock) + 1
        ELSE :criterion_clock END) AS "bclk_vcflag_by_score"
    FROM "t_vcflag" AS "t"
    WHERE t.vcflag = 1
    GROUP BY t.score)
  ,"t_remainflag" AS (
    SELECT t.*
      ,(CASE WHEN t.recent_clock < v.bclk_vcflag_by_score
        THEN 1 ELSE NULL END) AS "remainflag"
    FROM "t_vcflag" AS "t", "v_vcflag_by_score" AS "v"
    WHERE t.score = v.score_vcflag_by_score)
  ,"v_remainflag" AS (
    SELECT COUNT(1) AS "cnt_total_remainflag"
      ,COUNT(CASE WHEN t.remainflag IS NULL
        THEN 1 ELSE NULL END) AS "cnt_leaved_remainflag"
      ,COUNT(CASE WHEN t.remainflag = 1 AND t.vcflag = 1
        THEN 1 ELSE NULL END) AS "cnt_remain_remainflag"
    FROM "t_remainflag" AS "t")
  ,"v_remainflag_by_score" AS (
    SELECT t.score AS "score_remainflag_by_score"
      ,COUNT(1) AS "cnt_total_remainflag_by_score"
      ,COUNT(CASE WHEN t.remainflag IS NULL
        THEN 1 ELSE NULL END) AS "cnt_leaved_remainflag_by_score"
      ,COUNT(CASE WHEN t.remainflag = 1 AND t.vcflag = 1
        THEN 1 ELSE NULL END) AS "cnt_remain_remainflag_by_score"
    FROM "t_remainflag" AS "t"
    GROUP BY t.score)
  ,"v_sum_by_score" AS (
    SELECT SUM(v.cnt_total_remainflag_by_score) AS "sum_total_by_score"
      ,SUM(v.cnt_leaved_remainflag_by_score) AS "sum_leaved_by_score"
      ,SUM(v.cnt_remain_remainflag_by_score) AS "sum_remain_by_score"
    FROM "v_remainflag_by_score" as "v"
    WHERE v.score_remainflag_by_score
      BETWEEN :score_min AND :score_max)
  ,"t_contents" AS (
    SELECT *
    FROM "t_remainflag"
      ,"v_whole"
      ,"v_whole_by_score"
      ,"v_vcflag_by_score"
      ,"v_remainflag"
      ,"v_remainflag_by_score"
      ,"v_sum_by_score"
    WHERE score = score_whole_by_score
      AND score = score_vcflag_by_score
      AND score = score_remainflag_by_score)
EOF_SQL

SQL_CONTENTS_GET_VCINFO = <<-"EOF_SQL"
#{SQL_WITH_CLAUSE}
SELECT v.*
FROM "v_whole_by_score" AS "v"
EOF_SQL

SQL_CONTENTS_RANDOM   = <<-"EOF_SQL"
#{SQL_WITH_CLAUSE}
  ,"t_scored" AS (
    SELECT t.*
    FROM "t_contents" AS "t", "v_whole" AS "v"
    WHERE t.remainflag = 1
      AND t.vcflag = 1
      AND t.score
        BETWEEN MAX(v.lscore_whole, :score_min)
            AND MIN(v.hscore_whole, :score_max))
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
FROM "t_scored" AS "t", "r_scored" AS "r"
WHERE t.ids256 = r.l_ids256;
EOF_SQL

SQL_CONTENTS_SPECIFIED  = <<-"EOF_SQL"
#{SQL_WITH_CLAUSE}
SELECT *
FROM "t_contents"
WHERE ids256 = :ids256;
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
  attr_accessor(:score_llimit)
  attr_accessor(:score_hlimit)
  attr_accessor(:score_newval)
  attr_accessor(:history_idx)
  attr_accessor(:history_lst)

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

  def show_info(_entry = Hash.new())
    @cons.clear_screen    unless @debug_mode
    pp _entry             if @debug_mode

    if @history_idx > 0 then
      _view_mode = '直近履歴コンテンツ閲覧: (' << [@history_idx, '/', @history_lst.length].join('') << ')'
    else
      _view_mode = 'スコア範囲ランダム閲覧: (' << [@score_llimit, '..', @score_hlimit].join('') << ')'
    end
    _score_str = _entry['score'].to_s
    _score_str << ' → ' << @score_newval.to_s   if _entry['score'] != @score_newval
    puts   ''
    puts   '閲覧モード   : ' << _view_mode
    puts   'ファイル数   : 閲覧済 / 閲覧対象 / 全体総数'
    printf "    全体総数 : %6d : %8d : %8d\n", \
      _entry['cnt_leaved_remainflag'] + 1,  \
      _entry['cnt_leaved_remainflag'] + _entry['cnt_remain_remainflag'],  \
      _entry['cnt_whole']
    printf "  対象スコア : %6d : %8d : %8d\n", \
      _entry['sum_leaved_by_score'] + 1,    \
      _entry['sum_leaved_by_score'] + _entry['sum_remain_by_score'],  \
      _entry['sum_total_by_score']
    printf "  個別スコア : %6d : %8d : %8d\n",      \
      _entry['cnt_leaved_remainflag_by_score'] + 1, \
      _entry['cnt_leaved_remainflag_by_score'] + _entry['cnt_remain_remainflag_by_score'],  \
      _entry['cnt_total_remainflag_by_score']
    puts   '作品タイトル : ' << File.basename(File.dirname(_entry['relpath']))
    puts   '書名         : ' << _entry['filename']
    puts   'スコア       : ' << _score_str
    puts   '閲覧回数時間 : ' << [_entry['view_count'], '回', '/', _entry['elapsed_sec'], '秒'].join(' ')
    puts   ''
  end

  def view_rand()
    @cons = FrUtils::Console.new()

    _listdb = SQLite3::Database.new(File.join(SELF_PATH, FILNAME_DB))
    begin
      _listdb.transaction         if @debug_mode
      begin
        _listdb.results_as_hash = true
        begin
          _criterion_clock  = Time.now.to_i
          _proc_mode        = Array.new()
          _proc_mode.push(PROCESS_SHOW_NEXT)
          # main loop
          loop do
            # get and process random one target file
            _clause = Hash.new()
            _clause.store(:criterion_clock, _criterion_clock)
            if _proc_mode.include?(PROCESS_SHOW_PREV) \
              and @history_lst.length >= @history_idx then
              @history_idx = [@history_lst.length, @history_idx.succ].min
              _proc_mode.delete(PROCESS_SHOW_PREV)
              _proc_mode.push(PROCESS_SHOW_NEXT)
              _sql = SQL_CONTENTS_SPECIFIED
              _clause.store(:ids256, @history_lst[@history_idx.pred])
            elsif _proc_mode.include?(PROCESS_SHOW_NEXT) \
              and @history_idx > 1 then
              @history_idx = [0, @history_idx.pred].max
              _proc_mode.delete(PROCESS_SHOW_PREV)
              _proc_mode.push(PROCESS_SHOW_NEXT)
              _sql = SQL_CONTENTS_SPECIFIED
              _clause.store(:ids256, @history_lst[@history_idx.pred])
            else
              @history_idx = [0, @history_idx.pred].max
              _sql = SQL_CONTENTS_RANDOM
            end
            [ PROCESS_IMMEDIATE, PROCESS_BREAK,
              PROCESS_SCORE_INC, PROCESS_SCORE_DEC,
              PROCESS_REMOVE, ].each {|_proc|
              _proc_mode.delete(_proc)
            }

            _vcinfo = Hash.new()
            _listdb.execute(SQL_CONTENTS_GET_VCINFO).each {|_entry|
              _vcinfo.store(_entry['score_whole_by_score'],
                Range.new(_entry['lvc_by_score'],
                          _entry['hvc_by_score']))
            }
            _clause.store(:score_min, @score_llimit)
            _clause.store(:score_max, @score_hlimit)
            _listdb.execute(_sql, _clause).each {|_entry|
              # block per random one target file
              @score_newval = _entry['score']
              _view_count   = _entry['view_count']
              unless _clause.has_key?(:ids256) then
                @history_lst.unshift(_entry['ids256'])
                @history_lst = @history_lst.shift(HISTORY_LIMIT)
              end
              show_info(_entry)

              _st_clock = Time.now.to_i
              system(APP_VIEWER, *[File.join(PATH_MEDIA, _entry['relpath'])])
              _ed_clock = Time.now.to_i

              while (print '> '; _input_str = STDIN.getch(min: 0, time: INTERVAL_SECOND, intr: true))
                # console real-time, echoback-off, unbuffered I/O
                _input_print  = _input_str
                _input_byte   = _input_str.unpack('C*').first
                _input_binstr = _input_str.unpack('H*')
                _proc_mode.uniq!
                case _input_str
                when  *["\u0003", "\C-c",             # CTRL+C
                        "\u0004", "\C-d",     ] then  # CTRL+D
                  _proc_mode.push(PROCESS_BREAK)
                when  *["\u001b", "\e",       ] then  # Escape
                  _proc_mode.push(PROCESS_BREAK)
                  _input_print = '[ESC]'
                when  *["\u000a", "\n",       ] then  # LF Line Feed
                  @cons.clear_line(FrUtils::MODE_CLR_AFTER)
                  _input_print = '[LF]'
                when  *["\u000d", "\r",       ] then  # CR Carriage Return
                  @cons.clear_line(FrUtils::MODE_CLR_AFTER)
                  _input_print = '[CR]'
                when  *["\u0008", "\b",       ] then  # BackSpace
                  _input_print = '[BackSpace]'
                when  *["\u007f",             ] then  # Delete
                  _input_print = '[Delete]'
                when  *["\u0020", "\s", ' ',  ] then  # Space
                  _proc_mode.push(PROCESS_IMMEDIATE)
                  _input_print = '[Space]'
                when  *["\u0044",       'D',          # 'D'
                        "\u0064",       'd',  ] then  # 'd'
                  _proc_mode.push(PROCESS_REMOVE)
                when  *["\u002f",       '/',  ] then  # '/'
                  if @history_lst.length >= @history_idx then
                    _proc_mode.delete(PROCESS_SHOW_NEXT)
                    _proc_mode.push(PROCESS_SHOW_PREV)
                  end
                  _proc_mode.push(PROCESS_IMMEDIATE)
                when  *["\u002d",       '-',          # '-'
                        "\u005a",       'Z',          # 'Z'
                        "\u007a",       'z',  ] then  # 'z'
                  _proc_mode.delete(PROCESS_IMMEDIATE)
                  _proc_mode.delete(PROCESS_SCORE_INC)
                  if _proc_mode.include?(PROCESS_SCORE_DEC) then
                    _proc_mode.delete(PROCESS_SHOW_PREV)
                    _proc_mode.push(PROCESS_SHOW_NEXT)
                    _proc_mode.push(PROCESS_IMMEDIATE)
                  end
                  _proc_mode.push(PROCESS_SCORE_DEC)    if @score_newval == SCORE_RANGE.first
                  @score_newval = [@score_newval.pred, SCORE_RANGE.first].max
                when  *["\u002b",       '+',          # '+'
                        "\u0058",       'X',          # 'X'
                        "\u0078",       'x',  ] then  # 'x'
                  _proc_mode.delete(PROCESS_IMMEDIATE)
                  _proc_mode.delete(PROCESS_SCORE_DEC)
                  if _proc_mode.include?(PROCESS_SCORE_INC) then
                    _proc_mode.delete(PROCESS_SHOW_PREV)
                    _proc_mode.push(PROCESS_SHOW_NEXT)
                    _proc_mode.push(PROCESS_IMMEDIATE)
                  end
                  _proc_mode.push(PROCESS_SCORE_INC)    if @score_newval == SCORE_RANGE.last
                  @score_newval = [@score_newval.succ, SCORE_RANGE.last].min
                when  *["\u0056",       'V',          # 'V'
                        "\u0076",       'v',  ] then  # 'v'
                  @score_llimit = [@score_llimit.pred, SCORE_RANGE.first].max
                when  *["\u0042",       'B',          # 'B'
                        "\u0062",       'b',  ] then  # 'b'
                  @score_llimit = [@score_llimit.succ, SCORE_RANGE.last].min
                  @score_hlimit = @score_llimit   if @score_llimit > @score_hlimit
                when  *["\u004e",       'N',          # 'N'
                        "\u006e",       'n',  ] then  # 'n'
                  @score_hlimit = [@score_hlimit.pred, SCORE_RANGE.first].max
                  @score_llimit = @score_hlimit   if @score_llimit > @score_hlimit
                when  *["\u004d",       'M',          # 'M'
                        "\u006d",       'm',  ] then  # 'm'
                  @score_hlimit = [@score_hlimit.succ, SCORE_RANGE.last].min
                else                            # Other keys
                  if (0x01 .. (?Z.ord - ?A.ord)).cover?(_input_byte) then
                    _input_print = 'Ctrl-' << [_input_byte + 0x40].pack('C*')
                  end
                end
                show_info(_entry)
                puts "Input: #{_input_binstr}, '#{_input_print}'"
                puts ''
                break if _proc_mode.include?(PROCESS_IMMEDIATE)
                break if _proc_mode.include?(PROCESS_BREAK)
              end

              if _entry['score'] == @score_newval then
                _view_count = _clause.has_key?(:ids256) ? _entry['view_count'] : _entry['view_count'].succ
              elsif _vcinfo.has_key?(@score_newval)
                _view_count = _vcinfo[@score_newval].first
              end
              _listdb.execute(SQL_CONTENTS_UPDATE_REFDATA,
                :ids256         => _entry['ids256'],
                :view_count     => _view_count,
                :recent_clock   => _st_clock,
                :elapsed_sec    => [_ed_clock - _st_clock, ELAPSED_LIMIT].min,
                :content_score  => @score_newval,
                :flag           => (_proc_mode.include?(PROCESS_REMOVE) ? 1 : 0),
              )
            }
            break if _proc_mode.include?(PROCESS_BREAK)
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
    @debug_mode   = false
    @score_llimit = SCORE_RANGE.first
    @score_hlimit = SCORE_RANGE.last
    @score_newval = SCORE_INITIAL
    @history_idx  = 0
    @history_lst  = Array.new()
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
