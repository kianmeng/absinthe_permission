defmodule Absinthe.Permission do
  @moduledoc """

  """

  @behaviour Absinthe.Middleware

  alias Absinthe.Permission.PolicyCheck

  # check permission
  def call(
        %{
          state: :unresolved,
          arguments: arguments,
          context: %{auth: %{permissions: user_perms} = auth_context}
        } = res,
        _config
      ) do
    meta =
      case Absinthe.Type.meta(res.definition.schema_node) do
        m when m == %{} ->
          type = Absinthe.Schema.lookup_type(res.schema, res.definition.schema_node.type)
          Absinthe.Type.meta(type)

        m ->
          m
      end

    perm = Map.get(meta, :required_permission)

    case PolicyCheck.has_permission?(perm, user_perms) do
      false ->
        res |> Absinthe.Resolution.put_result({:error, "Unauthorized"})

      true ->
        conditions = Map.get(meta, :policies, [])
        result = PolicyCheck.should_we_allow?(Map.to_list(arguments), conditions, auth_context)

        case result do
          false ->
            res |> Absinthe.Resolution.put_result({:error, "Unauthorized"})

          true ->
            res
        end
    end
  end

  # sanitize
  def call(
        %{
          state: :resolved,
          arguments: args,
          context: %{auth: %{permissions: user_perms} = user_context}
        } = res,
        _config
      ) do
    meta = Absinthe.Type.meta(res.definition.schema_node)

    access_perms = Map.get(meta, :policies)

    case access_perms do
      nil ->
        res

      _v ->
        req_perms =
          access_perms |> Enum.map(&Keyword.get(&1, :required_permission)) |> MapSet.new()

        no_perms = MapSet.difference(req_perms, MapSet.new(user_perms)) |> Enum.to_list()

        case no_perms do
          [] ->
            res

          _ps ->
            fs =
              access_perms
              |> Enum.filter(&(Keyword.get(&1, :required_permission) in no_perms))
              |> Enum.flat_map(fn p ->
                {_, conds} = Keyword.pop(p, :required_permission)
                conds
              end)

            val = PolicyCheck.reject(res.value, fs, args, user_context)
            %{res | value: val}
        end
    end
  end

  # white list some paths and deny all others.
  def call(res, _config), do: res
end
