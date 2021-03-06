defmodule ApiServer.ApiController do
  use ApiServer.Web, :controller
  alias ApiServer.Format.Utils
  alias ApiServer.Manifest.Server, as: Manifests

  @doc """
  Returns the manifest metadata for the specified theme.
  """
  def info(conn, %{"theme"=>theme}) do
    manifests =
      Manifests.list_manifests(:lookup, theme)
      |> Enum.map(&get_service_basics/1)

    json conn, manifests
  end

  @doc """
  Returns status and info about the system
  """
 def status(conn, _) do
    {:ok, vsn} = :application.get_key(:api_server, :vsn)

    json conn, %{
        version: List.to_string(vsn)
    }
  end


  @doc """
  Returns the manifest metadata for all of the themes
  """
  def info(conn, %{}) do
    manifests = Manifests.list_themes(:lookup)
    |> Enum.map(fn theme->
      IO.inspect theme.id
      services =
        Manifests.list_manifests(:lookup, theme.id)
        |> Enum.map(&get_service_basics/1)
      {theme.id, services}
    end)
    |> Enum.into(%{})

    json conn, manifests
  end

  @doc """
  Returns the distinct data for the specified theme
  """
  def distinct(conn, %{"theme"=>theme, "service"=>service}) do
    d = :distincts |> Database.Lookups.find(theme)
    case d do
      nil ->
        conn |> put_status(404) |> json %{}
      _ ->
        json conn, d |> Dict.get(service, %{})
    end
  end
  def distinct(conn, %{"theme"=>theme}) do
    d = :distincts |> Database.Lookups.find(theme)
    case d do
      nil ->
        conn |> put_status(404) |> json %{}
      _ ->
        json conn, d
    end
  end

  defp get_service_basics(nil), do: %{}
  defp get_service_basics(m) do
     %{
        "name": m.tablename,
        "description": m.title,
        "dataset": m.dataset,
      }
  end


  @doc """
  A raw SQL endpoint for the specified theme. The schema should have been
  send as part of the theme action...
  """
  def theme_sql(conn, %{"theme"=>theme, "_format"=>format}=params) do

    res = Database.Schema.call_sql_api(params["query"], format: format)

    case format do
      "csv" ->
        results = Map.get(res, "result" )

        rows = Enum.map(results, fn m ->
          Map.values(m)
        end)

        schema = case hd(results) do
          m when is_map(m) ->
            Map.keys(m)
          _ -> []
        end

        conn
        |> write_csv schema, rows
      "ttl" ->
        conn
        |> put_layout(false)
        |> put_resp_content_type("application/x-turtle; charset=utf-8")
        |> put_resp_header("content-disposition",
                           "attachment; filename=\"query.ttl\";")
        |> assign(:objects, Map.get(res, "result"))
        |> assign(:base, url_for_ttl_base(conn, theme, ""))
        |> render "ttl.html"
      _ ->
        conn |> put_status(400)
    end
  end

  def theme_sql(conn, %{"query"=>query}) do
    # TODO: Still need to limit these properly ...
      conn
      |> json Database.Schema.call_sql_api(query)
  end

  defp validate_query(theme, service, query) do
    large = Dict.get(service, "large_dataset", false)
    validate_query_large_dataset(theme, query, large)
  end

  defp validate_query_large_dataset(_, _, false), do: {true, nil}
  defp validate_query_large_dataset(theme, query, true) do
    { limited, count } = Database.Schema.check_query_limit(theme, query)
    process_validation_matches limited, count
  end

  defp process_validation_matches(false, _), do: {false, "A limit is required on large datasets"}
  defp process_validation_matches(true, size) when size > 500 do
    {false, "Limits must be 500 or less"}
  end
  defp process_validation_matches(true, size) do
    {true, nil}
  end

  defp write_csv(conn, schema, data) do
      decoded  = data |> Enum.map(fn x-> Enum.map(x, &Utils.flatten_tabular/1) end)
      csv_stream = [schema|decoded] |> CSV.encode

      conn
      |> put_layout(false)
      |> put_resp_content_type("text/csv; charset=utf-8")
      |> put_resp_header("content-disposition",
                         "attachment; filename=\"query.csv\";")
      |> assign(:csv_stream, csv_stream)
      |> render "csv.html"
  end

  @doc """
  Calls the actual API endpoint within a theme
  """
  def service(conn, %{"theme"=>theme, "service"=>service,
                      "method"=>method, "_format"=>format}=params) do

    manifest = Manifests.get_manifest(:lookup, theme, service)
    [svc] = manifest.queries
    |> Enum.filter(fn s-> s.name == method end)

    res = process_api_call(params ,svc, format)
    schema = Map.keys(Database.Schema.get_schema(service))

    case format do
      "csv" ->
        rows = Enum.map(res, fn m ->
          Map.values(m)
        end)

        conn
        |> write_csv schema, rows
      "ttl" ->
        conn
        |> put_layout(false)
        |> put_resp_content_type("application/x-turtle; charset=utf-8")
        |> put_resp_header("content-disposition",
                           "attachment; filename=\"query.ttl\";")
        |> assign(:objects, res)
        |> assign(:base, url_for_ttl_base(conn, theme, service))
        |> render "ttl.html"
      _ ->
        conn |> put_status(400)
    end
  end

  def service(conn, %{"theme"=>theme, "service"=>service,
                      "method"=>method}=params) do

    manifest = Manifests.get_manifest(:lookup, theme, service)
    [svc] = manifest.queries
    |> Enum.filter(fn s-> s.name == method end)

    case process_api_call(params, svc, nil) do
      {:error, error} ->
          conn
          |> json %{"success"=> false, "error"=> error}
      nil ->
          conn |> put_status(400)
      res ->
          conn
          |> json %{"success"=>true, "result"=>res}
    end
  end

  @doc """
  Support for querying the endpoint directly by calling it with all of the
  required filters in query params, returned as CSV
  """
  def service_direct(conn, %{"_theme"=>theme, "_service"=>service, "_format"=>format}=params) do

    parameters = params
    |> Enum.filter(fn {k, _}-> !String.starts_with?(k, "_")  end)
    |> Enum.filter(fn {_, v}-> String.length(v) > 0  end)
    |> Enum.into %{}

    {query, arguments} = service_direct_query(parameters, service)
    res = Database.Schema.call_api(query, arguments, format: format)

    schema = Map.keys(Database.Schema.get_schema(service))

    case format do
      "csv" ->
        rows = Enum.map(res, fn m ->
          Map.values(m)
        end)

        conn
        |> write_csv schema, rows
      "ttl" ->
        conn
        |> put_layout(false)
        |> put_resp_content_type("application/x-turtle; charset=utf-8")
        |> put_resp_header("content-disposition",
                           "attachment; filename=\"query.ttl\";")
        |> assign(:objects, res)
        |> assign(:base, url_for_ttl_base(conn, theme, service))
        |> render "ttl.html"
      end
  end

  @doc """
  Support for querying the endpoint directly by calling it with all of the
  required filters in query params ....
  """
  def service_direct(conn, %{"_theme"=>theme, "_service"=>service}=params) do
    # We want a params dict without theme and service in it ....
    parameters = params
    |> Enum.filter(fn {k, _}-> !String.starts_with?(k, "_")  end)
    |> Enum.filter(fn {_, v}-> String.length(v) > 0  end)
    |> Enum.into %{}

    service_direct_process(conn, theme, parameters, service)
  end

  defp service_direct_process(conn, _theme, m, _service) when map_size(m) == 0 do
    conn
    |> json %{"success"=> false, "error"=> "No filters were supplied"}
  end
  defp service_direct_process(conn, _theme, parameters, service) do

    {query, arguments} = service_direct_query(parameters, service)

    res = Database.Schema.call_api(query, arguments)
    case res do
      {:error, error} ->
          conn
          |> json %{"success"=> false, "error"=> error}
      res ->
          conn
          |> json %{"success"=>true, "result"=>res}
    end
  end


  defp service_direct_query(parameters, service) do
    qparams = parameters
    |> Enum.with_index
    |> Enum.map(fn {{k, _}, pos} ->
        "#{k}=$#{pos+1} "
    end)
    |> Enum.join( " AND ")

    arguments = parameters
    |> Enum.map(fn {_, v} ->
        v
    end)

    query = "SELECT * FROM #{service} where #{qparams}"
    {query, arguments}
  end

  @doc """
  Documentation for the particular service.
  """
  def service_docs(conn, %{"theme"=>theme, "service"=>service}=_params) do
    conn
    |> assign(:theme, theme)
    |> assign(:service, service)
    |> render("docs.html")
  end


  @doc false
  defp process_api_call(params,
                       %{:query=>query, :fields=>fields},
                       fmt) do

    try do
      parameters = case fields do
        nil -> []
        _ -> Enum.map(fields, fn f ->
               %{:name=>name, :type=>type} =  f
               Utils.convert( Map.get(params, name), type )
             end)
      end

      if Enum.all?(parameters,  fn x -> x != "" end) do
        Database.Schema.call_api(query, parameters, format: fmt)
      else
        {:error, "Parameters are required"}
      end
    catch
      {:conversion_fail, msg} ->
          {:error, msg}
    end
  end
  @doc false
  defp process_api_call(_params, %{:query=>query}, fmt) do
    Database.Schema.call_api(query, [], format: fmt)
  end
  defp process_api_call(_, nil, _), do: nil

  defp url_for_ttl_base(conn, theme, service) do
      "#{get_host(conn)}/#{theme}/#{service}"
  end

  def get_host(conn) do
    host_url(conn.host, conn.port)
  end
  defp host_url(host, 80), do: "#{host}"
  defp host_url(host, port), do: "#{host}:#{port}"



end
