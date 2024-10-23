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
    SELECT "contents".*
    FROM "contents"
    WHERE flag = #{FLAG_NORMAL})
  ,"v_whole" AS (
    SELECT COUNT(1) AS "cnt_whole"
      ,MIN(score) AS "min_score"
      ,MAX(score) AS "max_score"
    FROM "t_whole")
  ,"v_whole_by_score" AS (
    SELECT score AS "score_whole_by_score"
      ,COUNT(1) AS "cnt_whole_by_score"
      ,MIN(view_count) AS "min_vc_by_score"
      ,MAX(view_count) AS "max_vc_by_score"
      ,(CASE WHEN MIN(view_count) = MAX(view_count)
        THEN MAX(view_count) + 1
        ELSE MAX(view_count) END) AS "bound_vc_by_score"
    FROM "t_whole"
    GROUP BY score)
  ,"t_vcflag" AS (
    SELECT "t_whole".*
      ,(CASE WHEN view_count < bound_vc_by_score THEN 1 ELSE NULL END) AS "vc_flag"
    FROM "t_whole", "v_whole_by_score"
    WHERE score = score_whole_by_score)
  ,"v_vcflag_by_score" AS (
    SELECT score AS "score_vcflag_by_score"
      ,COUNT(1) AS "cnt_vcflag_by_score"
      ,MIN(recent_clock) AS "min_clk_vcflag_by_score"
      ,MAX(recent_clock) AS "max_clk_vcflag_by_score"
      ,(CASE WHEN MIN(recent_clock) > :criterion_clock
        THEN MAX(recent_clock) + 1
        ELSE :criterion_clock END) AS "bound_clk_vcflag_by_score"
    FROM "t_vcflag"
    WHERE vc_flag = 1
    GROUP BY score)
  ,"t_remainflag" AS (
    SELECT "t_vcflag".*
      ,(CASE WHEN recent_clock < bound_clk_vcflag_by_score THEN 1 ELSE NULL END) AS "remain_flag"
    FROM "t_vcflag", "v_vcflag_by_score"
    WHERE score = score_vcflag_by_score)
  ,"v_remainflag" AS (
    SELECT COUNT(1) AS "cnt_remainflag"
      ,COUNT(CASE WHEN remain_flag IS NULL
        THEN 1 ELSE NULL END) AS "cnt_leaved_remainflag"
      ,COUNT(CASE WHEN remain_flag = 1 AND vc_flag = 1
        THEN 1 ELSE NULL END) AS "cnt_remain_remainflag"
      ,COUNT(CASE WHEN remain_flag = 1 AND vc_flag IS NULL
        THEN 1 ELSE NULL END) AS "cnt_prvmax_remainflag"
    FROM "t_remainflag")
  ,"v_remainflag_by_score" AS (
    SELECT score AS "score_remainflag_by_score"
      ,COUNT(1) AS "cnt_remainflag_by_score"
      ,COUNT(CASE WHEN remain_flag IS NULL
        THEN 1 ELSE NULL END) AS "cnt_leaved_remainflag_by_score"
      ,COUNT(CASE WHEN remain_flag = 1 AND vc_flag = 1
        THEN 1 ELSE NULL END) AS "cnt_remain_remainflag_by_score"
      ,COUNT(CASE WHEN remain_flag = 1 AND vc_flag IS NULL
        THEN 1 ELSE NULL END) AS "cnt_prvmax_remainflag_by_score"
    FROM "t_remainflag"
    GROUP BY score)
  ,"v_sum_by_score" AS (
    SELECT e.score_remainflag_by_score AS "score_sum_by_score"
      ,(SELECT SUM(av.cnt_remainflag_by_score)
        FROM "v_remainflag_by_score" AS av
        WHERE av.score_remainflag_by_score >= e.score_remainflag_by_score) AS "sum_by_score"
      ,(SELECT SUM(lv.cnt_leaved_remainflag_by_score)
        FROM "v_remainflag_by_score" AS lv
        WHERE lv.score_remainflag_by_score >= e.score_remainflag_by_score) AS "sum_leaved_by_score"
      ,(SELECT SUM(rv.cnt_remain_remainflag_by_score)
        FROM "v_remainflag_by_score" AS rv
        WHERE rv.score_remainflag_by_score >= e.score_remainflag_by_score) AS "sum_remain_by_score"
      ,(SELECT SUM(lv.cnt_prvmax_remainflag_by_score)
        FROM "v_remainflag_by_score" AS lv
        WHERE lv.score_remainflag_by_score >= e.score_remainflag_by_score) AS "sum_prvmax_by_score"
    FROM "v_remainflag_by_score" as e
    WHERE e.score_remainflag_by_score = :target_score)
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

SQL_CONTENTS_RANDOM   = <<-"EOF_SQL"
#{SQL_WITH_CLAUSE}
  ,"t_scored" AS (
    SELECT *
    FROM "t_contents"
    WHERE remain_flag = 1
      AND vc_flag = 1
      AND score >= MAX(min_score,MIN(max_score,:target_score)))
SELECT *
FROM "t_scored"
LIMIT 1
OFFSET ABS(RANDOM()) % MAX((
  SELECT COUNT(1) FROM "t_scored"), 1);
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

  def show_info(_entry = Hash.new(), _show_mode = '', _content_score = 1, _target_score = 1)
    @cons.clear_screen    unless @debug_mode
    pp _entry             if @debug_mode

    _show_mode = "ランダム閲覧: (対象スコア #{_target_score} 以上)"   if _show_mode.nil? || _show_mode.empty?
    if _entry['score'] == _content_score then
      _score_str = _entry['score'].to_s
    else
      _score_str = _entry['score'].to_s \
        << ' → ' << _content_score.to_s
    end
    puts   ''
    puts   '閲覧モード   : ' << _show_mode
    puts   'ファイル数   :  閲覧済 / 閲覧対象 / 全体総数'
    printf "    全体総数 : %7d : %8d : %8d\n",  \
      _entry['cnt_leaved_remainflag'] + 1,      \
      _entry['cnt_leaved_remainflag'] + _entry['cnt_remain_remainflag'],  \
      _entry['cnt_whole']
    printf "  対象スコア : %7d : %8d : %8d\n",  \
      _entry['sum_leaved_by_score'] + 1,        \
      _entry['sum_leaved_by_score'] + _entry['sum_remain_by_score'],  \
      _entry['sum_by_score']
    printf "  個別スコア : %7d : %8d : %8d\n",      \
      _entry['cnt_leaved_remainflag_by_score'] + 1, \
      _entry['cnt_leaved_remainflag_by_score'] + _entry['cnt_remain_remainflag_by_score'],  \
      _entry['cnt_remainflag_by_score']
    puts   '作品タイトル : ' << File.basename(File.dirname(_entry['relpath']))
    puts   '書名         : ' << _entry['filename']
    puts   'スコア       : ' << _score_str
    puts   '閲覧回数     : ' << _entry['view_count'].to_s
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
            _clause.store(:target_score, _target_score)
            if _proc_mode.include?(PROCESS_SHOW_PREV) \
              and _recent_lst.length >= _recent_idx then
              _recent_idx = [_recent_lst.length, _recent_idx.succ].min
              _show_mode = '指定コンテンツ参照: ' << [_recent_idx, '/', _recent_lst.length].join(' ')
              _proc_mode.delete(PROCESS_SHOW_PREV)
              _proc_mode.push(PROCESS_SHOW_NEXT)
              _sql = SQL_CONTENTS_SPECIFIED
              _clause.store(:ids256, _recent_lst[_recent_idx.pred])
            elsif _proc_mode.include?(PROCESS_SHOW_NEXT) \
              and _recent_idx > 1 then
              _recent_idx = [0, _recent_idx.pred].max
              _show_mode = '指定コンテンツ参照: ' << [_recent_idx, '/', _recent_lst.length].join(' ')
              _proc_mode.delete(PROCESS_SHOW_PREV)
              _proc_mode.push(PROCESS_SHOW_NEXT)
              _sql = SQL_CONTENTS_SPECIFIED
              _clause.store(:ids256, _recent_lst[_recent_idx.pred])
            else
              _recent_idx = [0, _recent_idx.pred].max
              _show_mode = nil
              _sql = SQL_CONTENTS_RANDOM
            end
            [ PROCESS_IMMEDIATE, PROCESS_BREAK,
              PROCESS_SCORE_INC, PROCESS_SCORE_DEC,
              PROCESS_REMOVE, ].each {|_proc|
              _proc_mode.delete(_proc)
            }
            _listdb.execute(_sql, _clause).each {|_entry|
              # block per random one target file
              _content_score = _entry['score']
              unless _clause.has_key?(:ids256) then
                _recent_lst.unshift(_entry['ids256'])
                _recent_lst = _recent_lst.shift(10)
              end
              show_info(_entry, _show_mode, _content_score, _target_score)

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
                  _proc_mode.push(PROCESS_SCORE_DEC)    if _content_score == RANGE_SCORE.first
                  _content_score = [_content_score.pred, RANGE_SCORE.first].max
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
                  _proc_mode.push(PROCESS_SCORE_INC)    if _content_score == RANGE_SCORE.last
                  _content_score = [_content_score.succ, RANGE_SCORE.last].min
                when  *["\u003c",       '<',  ] then  # '<'
                  _target_score = [_target_score.pred, RANGE_SCORE.first].max
                when  *["\u003e",       '>',  ] then  # '>'
                  _target_score = [_target_score.succ, RANGE_SCORE.last].min
                else                            # Other keys
                  if (0x01 .. (?Z.ord - ?A.ord)).cover?(_input_byte) then
                    _input_print = 'Ctrl-' << [_input_byte + 0x40].pack('C*')
                  end
                end
                show_info(_entry, _show_mode, _content_score, _target_score)
                puts "Input: #{_input_binstr}, '#{_input_print}'"
                puts ''
                break if _proc_mode.include?(PROCESS_IMMEDIATE)
                break if _proc_mode.include?(PROCESS_BREAK)
              end

              _listdb.execute(SQL_CONTENTS_UPDATE_REFDATA,
                :ids256         => _entry['ids256'],
                :view_count     => (_clause.has_key?(:ids256) ? _entry['view_count'] : _entry['view_count'].succ),
                :recent_clock   => _st_clock,
                :elapsed_sec    => [_ed_clock - _st_clock, ELAPSED_LIMIT].min,
                :content_score  => _content_score,
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
