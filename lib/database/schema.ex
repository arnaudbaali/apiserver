defmodule Database.Schema do
  @moduledoc """
  This module contains all of the functions used to connect to the
  database for performing queries, and also fetching schema of tables.
  """
  alias Database.Worker

  def get_schemas(dbname) do
    q = """
      SELECT table_name, column_name, data_type
      FROM information_schema.columns
      WHERE table_schema = 'public';
    """
    pool = String.to_atom(dbname)

    :poolboy.transaction(pool, fn(worker)->
      {:ok, _, results} = Worker.query(worker, q)

      results
      |> Enum.group_by(fn x->
          elem(x, 0)
         end)
      |> Enum.map( fn {k, v} ->
          cells = Enum.map(v, fn x-> {elem(x, 1), elem(x, 2)} end)
          |> Enum.into(%{})
          {k, cells}
         end)
      |> Enum.into(%{})

    end)
  end

  def get_schema(dbname, table) do
    q = """
      SELECT column_name, data_type
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name   = '#{table}';
    """
    pool = String.to_atom(dbname)

    :poolboy.transaction(pool, fn(worker)->
      {:ok, _, results} = Worker.query(worker, q)
      Enum.into(results, %{})
    end)

  end

 def call_api(dbname, query, arguments \\ []) do

    ExStatsD.increment("query.#{dbname}.apicall")

    args = Enum.map(arguments, fn x -> to_char_list(x) end)
    pool = String.to_atom(dbname)

    :poolboy.transaction(pool, fn(worker)->
      {:ok, fields, data} = Worker.query(worker, query, args)

      columns = fields
      |> Enum.map(fn x -> elem(x, 1) end)

      results = data
      |> Enum.map(fn row ->
        row
        |> Tuple.to_list
        |> Enum.map(fn cell-> clean(cell) end)
        # Turn row into a list
      end)
      |> Enum.map(fn r -> Enum.zip(columns, r) end)
      |> Enum.map(fn res -> Enum.into(res, %{}) end )
    end)
  end

 def call_sql_api(dbname, query) do

    ExStatsD.increment("query.#{dbname}.sqlcall")

    pool = String.to_atom(dbname)

    :poolboy.transaction(pool, fn(worker)->
      {:ok, _, _} = Worker.query(worker, 'set statement_timeout to 3000;')
      resp = case Worker.raw_query(worker, query)  do
          {:ok, fields, data} ->
            columns = fields
            |> Enum.map(fn x -> elem(x, 1) end)

            results = data
            |> Enum.map(fn r -> Tuple.to_list(r) end)

            %{"columns"=>columns, "rows"=> results, "success" => true }
         {:error, {:error, :error, _, error, _}} ->
            %{"success"=> false, "error" => error}
         {:ok, 1} ->
            %{"success"=> false, "error" => "This is bad"}
        end
    end)
   end

  defp clean({{year, month, day}, {hr, mn, sec}}) do
    "#{day}/#{month}/#{year} #{filled_int(hr)}:#{filled_int(mn)}:#{filled_int(sec)}"
  end

  defp clean(val) do
     val
  end

  defp filled_int(i) when i < 10 do
    "0#{i}"
  end

  defp filled_int(i) do
    "#{i}"
  end

end
