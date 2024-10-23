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
RANGE_SCORE     = 1..10

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
  "score"         INTEGER NOT NULL  DEFAULT #{RANGE_SCORE.first},
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
  "score"         = :score,
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

SQL_CONTENTS_RANDOM   = <<-"EOF_SQL"
WITH
  "t_whole" AS (
    SELECT *
    FROM "contents"
    WHERE flag = #{FLAG_NORMAL})
  ,"v_whole" AS (
    SELECT COUNT(ids256) AS "cnt_whole"
      ,COUNT(CASE WHEN recent_clock <  :criterion_clock THEN ids256 ELSE NULL END) AS "cnt_remain_whole"
      ,COUNT(CASE WHEN recent_clock >= :criterion_clock THEN ids256 ELSE NULL END) AS "cnt_leaved_whole"
      ,MIN(score) AS "min_score"
      ,MAX(score) AS "max_score"
    FROM "t_whole")
  ,"t_scored" AS (
    SELECT t_whole.*
    FROM "t_whole", "v_whole"
    WHERE score >= MAX(min_score, MIN(max_score, :score)))
  ,"v_scored" AS (
    SELECT COUNT(ids256) AS "cnt_scored"
      ,COUNT(CASE WHEN recent_clock <  :criterion_clock THEN ids256 ELSE NULL END) AS "cnt_remain_scored"
      ,COUNT(CASE WHEN recent_clock >= :criterion_clock THEN ids256 ELSE NULL END) AS "cnt_leaved_scored"
    FROM "t_scored")
  ,"i_v_by_score" AS (
    SELECT score AS "score_by_score"
      ,COUNT(ids256) AS "cnt_all_by_score"
      ,COUNT(CASE WHEN recent_clock <  :criterion_clock THEN ids256 ELSE NULL END) AS "cnt_remain_by_score"
      ,COUNT(CASE WHEN recent_clock >= :criterion_clock THEN ids256 ELSE NULL END) AS "cnt_leaved_by_score"
      ,(CASE WHEN COUNT(ids256) > 0 THEN MIN(view_count) ELSE 0 END) AS "vc_min_by_score"
      ,(CASE WHEN COUNT(ids256) > 0 THEN MAX(view_count) ELSE 0 END) AS "vc_max_by_score"
    FROM "t_scored"
    GROUP BY score)
  ,"v_by_score" AS (
    SELECT *
      ,(CASE WHEN vc_min_by_score = vc_max_by_score
        THEN vc_max_by_score + 1
        ELSE vc_max_by_score END) AS "vc_bound_by_score"
    FROM "i_v_by_score")
  ,"i_v_by_score_vc" AS (
    SELECT score AS "score_by_score_vc"
      ,COUNT(CASE WHEN view_count < vc_bound_by_score THEN ids256 ELSE NULL END) AS "cnt_remain_by_score_vc"
      ,COUNT(CASE WHEN view_count = vc_bound_by_score THEN ids256 ELSE NULL END) AS "cnt_leaved_by_score_vc"
      ,MIN(CASE WHEN view_count < vc_bound_by_score
        THEN recent_clock
        ELSE :criterion_clock + 1000 END) AS "i_clk_min_by_score_vc"
      ,MAX(CASE WHEN view_count < vc_bound_by_score
        THEN recent_clock
        ELSE 0 END) AS "i_clk_max_by_score_vc"
    FROM "t_scored", "v_by_score"
    WHERE score = score_by_score
    GROUP BY score)
  ,"i2_v_by_score_vc" AS (
    SELECT *
      ,(CASE WHEN i_clk_min_by_score_vc IS NOT NULL
        THEN i_clk_min_by_score_vc
        ELSE 0 END) AS "clk_min_by_score_vc"
      ,(CASE WHEN i_clk_max_by_score_vc IS NOT NULL
        THEN i_clk_max_by_score_vc
        ELSE :criterion_clock + 1000 END) AS "clk_max_by_score_vc"
    FROM "i_v_by_score_vc")
  ,"v_by_score_vc" AS (
    SELECT *
      ,(CASE WHEN clk_min_by_score_vc = clk_max_by_score_vc
        THEN clk_max_by_score_vc + 1
        ELSE clk_max_by_score_vc END) AS "clk_bound_by_score_vc"
    FROM "i2_v_by_score_vc")
  ,"v_by_vc" AS (
    SELECT score_by_score_vc AS "score_by_vc"
      ,SUM(cnt_remain_by_score_vc) AS "cnt_remain_by_vc"
      ,SUM(cnt_leaved_by_score_vc) AS "cnt_leaved_by_vc"
    FROM "v_by_score_vc")
  ,"t_remain" AS (
    SELECT *
    FROM "t_scored"
      ,"v_whole"
      ,"v_scored"
      ,"v_by_score"
      ,"v_by_score_vc"
      ,"v_by_vc"
    WHERE view_count < vc_bound_by_score
      AND recent_clock < clk_bound_by_score_vc
      AND score = score_by_score
      AND score = score_by_score_vc)
SELECT *
FROM "t_remain"
LIMIT 1
OFFSET ABS(RANDOM()) % MAX((
  SELECT COUNT(ids256) AS "count_remain"
  FROM "t_remain"), 1);
EOF_SQL

SQL_CONTENTS_SPECIFIED  = <<-"EOF_SQL"
SELECT c.*
  ,tbl_total.cnt_total AS "cnt_whole"
  ,tbl_target.cnt_target AS "count_remain"
FROM "contents" AS "c"
  ,(SELECT COUNT(*) AS "cnt_total"
    FROM "contents" AS "tbl_total_i"
    WHERE tbl_total_i.flag = #{FLAG_NORMAL}
  ) AS "tbl_total"
  ,(SELECT COUNT(*) AS "cnt_target"
    FROM "contents" AS "tbl_target_i"
    WHERE tbl_target_i.flag = #{FLAG_NORMAL}
      AND tbl_target_i.recent_clock < :criterion_clock
      AND tbl_target_i.view_count = (
        SELECT MIN(tbl_minview_2.view_count)
        FROM "contents" AS "tbl_minview_2"
        WHERE tbl_minview_2.flag = #{FLAG_NORMAL}
      )
  ) AS "tbl_target"
WHERE c.flag = #{FLAG_NORMAL}
  AND c.ids256 = :ids256;
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
        _listdb.execute(SQL_CONTENTS_LIMIT_SCORE_MIN, :limit => RANGE_SCORE.first)
        _listdb.execute(SQL_CONTENTS_LIMIT_SCORE_MAX, :limit => RANGE_SCORE.last)
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

  def show_info(_entry = Hash.new(), _show_mode = '', _score = 1)
    @cons.clear_screen    unless @debug_mode
    pp _entry             if @debug_mode

    if _entry['score'] == _score then
      _score_str = _entry['score'].to_s
    else
      _score_str = _entry['score'].to_s \
        << ' → ' \
        << _score.to_s
    end
    puts ''
    puts '閲覧モード   : ' << _show_mode
    puts 'ファイル数   :  閲覧済 / 閲覧対象 / 全体総数'
    printf "    全体総数 : %7d : %8d : %8d\n",                 \
      _entry['cnt_leaved_whole'] + 1,                           \
      _entry['cnt_leaved_whole'] + _entry['cnt_remain_whole'],  \
      _entry['cnt_whole']
    printf "  対象スコア : %7d : %8d : %8d\n",                   \
      _entry['cnt_leaved_scored'] + 1,                            \
      _entry['cnt_leaved_scored'] + _entry['cnt_remain_scored'],  \
      _entry['cnt_scored']
    printf "  個別スコア : %7d : %8d : %8d\n",                             \
      _entry['cnt_leaved_by_score_vc'] + 1,                                 \
      _entry['cnt_leaved_by_score_vc'] + _entry['cnt_remain_by_score_vc'],  \
      _entry['cnt_all_by_score']
    puts '作品タイトル : ' << File.basename(File.dirname(_entry['relpath']))
    puts '書名         : ' << _entry['filename']
    puts 'スコア       : ' << _score_str
    puts '閲覧回数     : ' << _entry['view_count'].to_s
    puts ''
  end

  def view_rand()
    @cons = FrUtils::Console.new()

    _listdb = SQLite3::Database.new(File.join(SELF_PATH, FILNAME_DB))
    begin
      _listdb.transaction         if @debug_mode
      begin
        _listdb.results_as_hash = true
        begin
          _recent_idx       = 0
          _recent_lst       = Array.new()
          _criterion_clock  = Time.now.to_i
          _target_score     = 1
          _proc_mode        = Array.new()
          _proc_mode.push(PROCESS_SHOW_NEXT)
          # main loop
          loop do
            # get and process random one target file
            _clause = Hash.new()
            _clause.store(:criterion_clock, _criterion_clock)
            if _proc_mode.include?(PROCESS_SHOW_PREV) \
              and _recent_lst.length >= _recent_idx then
              _recent_idx = [_recent_lst.length, _recent_idx.succ].min
              _show_mode = 'Specified: ' << [_recent_idx, '/', _recent_lst.length].join(' ')
              _proc_mode.delete(PROCESS_SHOW_PREV)
              _proc_mode.push(PROCESS_SHOW_NEXT)
              _sql = SQL_CONTENTS_SPECIFIED
              _clause.store(:ids256, _recent_lst[_recent_idx.pred])
            elsif _proc_mode.include?(PROCESS_SHOW_NEXT) \
              and _recent_idx > 1 then
              _recent_idx = [0, _recent_idx.pred].max
              _show_mode = 'Specified: ' << [_recent_idx, '/', _recent_lst.length].join(' ')
              _proc_mode.delete(PROCESS_SHOW_PREV)
              _proc_mode.push(PROCESS_SHOW_NEXT)
              _sql = SQL_CONTENTS_SPECIFIED
              _clause.store(:ids256, _recent_lst[_recent_idx.pred])
            else
              _recent_idx = [0, _recent_idx.pred].max
              _show_mode = "ランダム閲覧: (対象スコア #{_target_score} 以上)"
              _sql = SQL_CONTENTS_RANDOM
              _clause.store(:score, _target_score)
            end
            [PROCESS_IMMEDIATE, PROCESS_BREAK, PROCESS_SCORE_INC, PROCESS_SCORE_DEC].each {|_proc|
              _proc_mode.delete(_proc)
            }
            _listdb.execute(_sql, _clause).each {|_entry|
              # block per random one target file
              _score = _entry['score']
              unless _clause.has_key?(:ids256) then
                _recent_lst.unshift(_entry['ids256'])
                _recent_lst = _recent_lst.shift(10)
              end
              unless ((_entry['cnt_remain_whole']  > 1) \
                and (_entry['cnt_remain_scored']   > 1) \
                and (_entry['cnt_remain_by_score'] > 1)) then
                _criterion_clock = _criterion_clock.succ
              end
              show_info(_entry, _show_mode, _score)

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
                when  *["\u0044",       'D',          # 'D'
                        "\u0064",       'd',  ] then  # 'd'
                  _proc_mode.push(PROCESS_REMOVE)
                when  *["\u002f",       '/',  ] then  # '/'
                  if _recent_lst.length >= _recent_idx then
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
                  _proc_mode.push(PROCESS_SCORE_DEC)    if _score == RANGE_SCORE.first
                  _score = [_score.pred, RANGE_SCORE.first].max
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
                  _proc_mode.push(PROCESS_SCORE_INC)    if _score == RANGE_SCORE.last
                  _score = [_score.succ, RANGE_SCORE.last].min
                when  *["\u003c",       '<',  ] then  # '<'
                  _target_score = [_target_score.pred, RANGE_SCORE.first].max
                  _proc_mode.push(PROCESS_IMMEDIATE)
                when  *["\u003e",       '>',  ] then  # '>'
                  _target_score = [_target_score.succ, RANGE_SCORE.last].min
                  _proc_mode.push(PROCESS_IMMEDIATE)
                else                            # Other keys
                  if (0x01 .. (?Z.ord - ?A.ord)).cover?(_input_byte) then
                    _input_print = 'Ctrl-' << [_input_byte + 0x40].pack('C*')
                  end
                end
                show_info(_entry, _show_mode, _score)
                puts "Input: #{_input_binstr}, '#{_input_print}'"
                puts ''
                break if _proc_mode.include?(PROCESS_IMMEDIATE)
                break if _proc_mode.include?(PROCESS_BREAK)
              end

              _listdb.execute(SQL_CONTENTS_UPDATE_REFDATA,
                :ids256       => _entry['ids256'],
                :view_count   => (_clause.has_key?(:ids256) ? _entry['view_count'] : _entry['view_count'].succ),
                :recent_clock => _st_clock,
                :elapsed_sec  => [_ed_clock - _st_clock, ELAPSED_LIMIT].min,
                :score        => _score,
                :flag         => (_proc_mode.include?(PROCESS_REMOVE) ? 1 : 0),
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
    @debug_mode = false
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
