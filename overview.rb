require 'spec_helper'

def w_indent indent_level, text
  out = ""

  indent_level.times do
    out = out + "\t"
  end

  wl("<p style=\"margin-left:#{indent_level}.0em\">#{out + text}</p>")
end

def w_indent_w_progress indent_level, text, index, total
  out = ""

  indent_level.times do
    out = out + "\t"
  end

  wl("<p style=\"margin-left:#{indent_level}.0em\">#{out + text}</p>")
  puts "#{index}/#{total}"
end


def record_column_with_zero_id column
  return if column["_ID"].nil?
  
  if [column] & @column_with_id_of_null_or_zero == []
    @column_with_id_of_null_or_zero << column
  end
end

def hl
  wl('<div style="border-top: 1px dotted black;"></div>')
end

def wl line
  @current_state_results.write(line)
end

def kv key, value
  "<strong>#{key}</strong>: #{value}"
end

def print_html_header
  wl '<?xml version="1.0" encoding="UTF-8"?>'
  wl '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">'
  wl '<head>'
  wl '<title>RSpec results</title>'
  wl '<meta http-equiv="Content-Type" content="text/html; charset=utf-8" />'
  wl '<meta http-equiv="Expires" content="-1" />'
  wl '<meta http-equiv="Pragma" content="no-cache" />'
  wl '<style type="text/css">'
  wl 'body { margin: 0; padding: 0; background: #fff; font-size: 80%; }'
  wl '</style>'
  wl '</head>'
  wl '<body>'
end

def print_html_footer
  wl '</body>'
  wl '</html>'
end

describe 'current_state', :db => 'rollback' do
  it 'looks like this' do
    @current_state_results = File.open("output.html", 'w')

    print_html_header

    sql = <<-SQL
        SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE, DATA_LENGTH, DATA_PRECISION, NULLABLE, DATA_DEFAULT
        FROM ALL_TAB_COLUMNS
        WHERE OWNER = 'SCHEMA_OWNER_CHANGE_THIS_XXXXXXXXXXXXXXXXXXXXXX'
        AND TABLE_NAME not like '%$%'
        order by table_name asc, column_id asc
    SQL

    current_table = ""
    current_col = ""
    records_in_table = 0

    @column_with_id_of_null_or_zero = []

    all_table_colums = DB[sql].all
    all_table_colums.each_with_index do |row, index|
      if row[:table_name] != current_table
        hl
        current_table = row[:table_name]
        w_indent_w_progress 0, "#{current_table.upcase}", index, all_table_colums.count

        total_records = <<-SQL
          SELECT /*+ parallel(t, 8)*/ count(1) as count
          FROM #{current_table} t
        SQL
        records_in_table = DB[total_records].all.first[:count]
        w_indent 1, "Number of Records: #{records_in_table}"
      end

      if row[:column_name] != current_col
        current_col = row[:column_name]
        w_indent_w_progress 1, current_col.upcase, index, all_table_colums.count
      end


      w_indent 2, kv("Data Type", row[:data_type])
      w_indent 2, kv("Data Default", row[:data_default].nil? ? "null" : row[:data_default])
      w_indent 2, kv("Data Length", row[:data_length])
      w_indent 2, kv("Data Precision", row[:data_precision].nil? ? "N/A" : row[:data_precision])
      w_indent 2, kv("Supports Nulls?", row[:nullable])


      has_nulls = <<-SQL
        SELECT /*+ parallel(t, 8)*/ count(1) as count
        FROM #{current_table} t
        WHERE t.#{current_col} IS NULL
      SQL
      has_nulls_result = DB[has_nulls].all.first[:count]
      w_indent 2, kv("Has Nulls?", has_nulls_result > 0)
      record_column_with_zero_id("#{current_table}.#{current_col.upcase}") if has_nulls_result > 0 and records_in_table > 0

      if records_in_table > 0
        min_max_value = <<-SQL
          SELECT /*+ parallel(t, 8)*/ MIN(#{current_col}) AS MIN, MAX(#{current_col}) AS MAX
          FROM #{current_table} t
        SQL
        value = DB[min_max_value].all
        w_indent 2, kv('Value min', value.first[:min])
        w_indent 2, kv('Value max', value.first[:max])
        record_column_with_zero_id("#{current_table} #{current_col.upcase}") if has_nulls_result == 0 if value.first[:min] == 0


        min_max_length = <<-SQL
          SELECT /*+ parallel(t, 8)*/ MIN(LENGTH(#{current_col})) AS MIN, MAX(LENGTH(#{current_col})) AS MAX
          FROM #{current_table}
        SQL
        length = DB[min_max_length].all
        w_indent 2, kv('Length min', length.first[:min])
        w_indent 2, kv('Length max', length.first[:max])


        # top 10
        w_indent 2, "Top 10 values for each column, unless an ID column and having more than 2 instances:"
        if current_col["_ID"].nil?
          top_10 = nil
          if row[:data_type] == "DATE"
            top_10 = <<-SQL
              SELECT  /*+ parallel(t, 8)*/ trunc(#{current_col}) as value, count(1) as count
              FROM #{current_table} t
              GROUP BY #{current_col}
              HAVING count(1) > 2
              ORDER BY count(1) desc
            SQL

            top_10 = DB[top_10].all
          else
            top_10 = <<-SQL
              SELECT  /*+ parallel(t, 8)*/ #{current_col} as value, count(1) as count
              FROM #{current_table} t
              GROUP BY #{current_col}
              HAVING count(1) > 2
              ORDER BY count(1) desc
            SQL

            top_10 = DB[top_10].all
          end

          top_10.each_with_index do |row, index|
            break if index == 10

            w_indent 3, kv(row[:value],row[:count])
          end

          if top_10.count == 0
            w_indent 2, "No rows meet the criteria"
          end
        else
          w_indent 2, "This is an ID column"
        end
      end
    end

    wl ""
    wl ""
    wl "Columns with ID fields that contain a zero or null:"
    @column_with_id_of_null_or_zero.each do |table_column|
      w_indent 1, table_column
    end

    @current_state_results.close
  end
end
