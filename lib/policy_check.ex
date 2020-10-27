defmodule Absinthe.Permission.PolicyCheck do
  @moduledoc """

  """

  alias Absinthe.Permission.DefaultFetcher

  @type condition :: Keyword.t()
  @type clause :: Keyword.t()

  @spec has_permission?(atom | binary, list(atom) | list(binary)) :: boolean
  def has_permission?(required_perm, user_perms)

  def has_permission?(nil, _), do: true

  def has_permission?(perm, user_perms) when is_atom(perm) do
    Atom.to_string(perm) in user_perms
  end

  def has_permission?(perm, user_perms) when is_binary(perm) do
    perm in user_perms
  end

  @spec should_we_allow?(Keyword.t(), list(), map()) :: boolean()
  def should_we_allow?(args, conds, context) do
    perms = allowed?(args, conds, context, [])

    case perms do
      [] ->
        true

      perms ->
        perms
        |> higher_permission
        |> has_permission?(context.permissions)
    end
  end

  @spec reject(list | map, list(atom | binary), list(map()), map()) :: map()
  def reject(val, filters, args, context) do
    reject(val, fn x -> checker(x, filters, Map.to_list(args), context) end)
  end

  @spec reject(list(), function()) :: list()
  def reject(val, fun) when is_list(val) do
    Enum.reject(val, fun)
  end

  @spec reject(map(), function()) :: map()
  def reject(val, fun) do
    Enum.reject([val], fun) |> List.first()
  end

  @spec higher_permission(list()) :: atom | binary
  defp higher_permission(permissions) do
    # TODO: if all conditions have same priority,
    # then instead of choosing first permission
    # we can give all permissions.
    # If user has one of them, then grant the access.
    # Should be discussed.
    if all_same_priority?(permissions) do
      permissions |> Enum.at(0) |> elem(0)
    else
      permissions
      |> Enum.max_by(fn {_k, v} -> v end)
      |> elem(0)
    end
  end

  @spec all_same_priority?(list()) :: boolean()
  defp all_same_priority?(permissions) do
    permissions
    |> Enum.map(fn {_k, v} -> v end)
    |> Enum.group_by(fn v -> v end)
    |> Map.keys()
    |> length == 1
  end

  @spec allowed?(Keyword.t(), list(), map(), list(atom | binary)) :: list()
  defp allowed?(args, conds, context, perms)

  # defp allowed?([], _, _context, perms) do
  #   perms
  # end

  defp allowed?(args, conditions, context, perms) do
    check_conds(conditions, args, context, perms)
  end

  @spec check_conds(list(condition), Keyword.t(), map(), list()) :: list()
  defp check_conds(conditions, args, context, perms)

  defp check_conds([], _args, _context, perms) do
    perms
  end

  defp check_conds(
         [condition | conds],
         args,
         context,
         perms
       ) do
    case check_cond(condition, args, context) do
      {true, counter} ->
        perm = Keyword.get(condition, :required_permission) |> String.to_atom()

        new_perm =
          case Keyword.get(perms, perm) do
            nil ->
              {perm, counter}

            curr_val ->
              case curr_val == counter do
                true -> {perm, curr_val}
                false -> {perm, counter}
              end
          end

        check_conds(conds, args, context, [new_perm | perms])

      _ ->
        check_conds(conds, args, context, perms)
    end
  end

  defp check_cond(condition, args, context) do
    check_clause(condition, condition, args, context, {true, 0})
  end

  @spec check_clause(list(clause), condition(), Keyword.t(), map(), {boolean(), integer()}) ::
          {boolean(), integer()}
  defp check_clause(clauses, condition, args, context, state)
  defp check_clause(_, _, _, _, {false, counter}), do: {false, counter}

  defp check_clause([], _condition, _args, _context, state), do: state

  defp check_clause(
         [{:remote_context, remote_context} | clauses],
         condition,
         args,
         context,
         state
       ) do
    fetcher =
      Application.get_env(
        :absinthe_permission,
        :fetcher,
        &DefaultFetcher.fetch/4
      )

    {:ok, result} =
      case fetcher do
        fun when is_function(fetcher) ->
          fun.(remote_context, condition, args, context)

        {module, fun} ->
          :erlang.apply(module, fun, [remote_context, condition, args, context])
      end

    # TODO: remove config keys from remote context.
    # Otherwise checker will try to check these fields and return false.
    res = checker(result, remote_context, args, context)

    check_clause(clauses, condition, args, context, increment(res, state))
  end

  defp check_clause(
         [{:user_context, user_context} | clauses],
         condition,
         args,
         %{current_user: current_user} = context,
         state
       ) do
    {remote_key, user_context} = Keyword.pop(user_context, :remote_key)
    {input_key, user_context} = Keyword.pop(user_context, :input_key)
    input_val = Keyword.get(args, input_key)
    op = Keyword.get(user_context, :op)

    case op do
      :eq ->
        check_clause(
          clauses,
          condition,
          args,
          context,
          increment(Map.get(current_user, remote_key) == input_val, state)
        )

      :neq ->
        check_clause(
          clauses,
          condition,
          args,
          context,
          increment(Map.get(current_user, remote_key) != input_val, state)
        )

      _ ->
        check_clause(clauses, condition, args, context, increment(false, state))
    end
  end

  defp check_clause(
         [{:required_permission, _cond_val} | clauses],
         condition,
         args,
         context,
         state
       ) do
    check_clause(clauses, condition, args, context, state)
  end

  defp check_clause(
         [{clause_key, {clause_val, op}} | clauses],
         condition,
         args,
         context,
         state
       ) do
    check_clause(
      clauses,
      condition,
      args,
      context,
      Keyword.get(args, clause_key) |> op_func(op).(clause_val) |> increment(state)
    )
  end

  defp check_clause([{clause_key, clause_val} | clauses], condition, args, context, state) do
    check_clause(
      [{clause_key, {clause_val, :eq}} | clauses],
      condition,
      args,
      context,
      state
    )
  end

  defp checker(result, checks, args, context) do
    checks
    |> Enum.map(fn
      {k, {v, op}} -> {k, v, op_func(op)}
      {k, v} -> {k, v, op_func(:eq)}
    end)
    |> Enum.map(fn {k, v, op} ->
      ks = k |> Atom.to_string() |> String.split("__") |> Enum.map(&String.to_atom/1)
      {ks, v, op}
    end)
    |> Enum.map(fn
      {ks, :current_user_id, op} -> {ks, context.current_user.id, op}
      {ks, v, op} when is_atom(v) -> {ks, Keyword.get(args, v) || v, op}
      {ks, v, op} -> {ks, v, op}
    end)
    |> Enum.all?(fn {ks, v, op} -> fetch(result, ks) |> op.(v) end)
  end

  defp increment(true, {_, counter}), do: {true, counter + 1}
  defp increment(false, {_, counter}), do: {false, counter}

  @spec op_func(atom()) :: function()
  defp op_func(op_key)
  defp op_func(:eq), do: &==/2
  defp op_func(:neq), do: &!=/2

  @spec fetch(map(), list(atom | binary)) :: any()
  defp fetch(container, keys)
  defp fetch(nil, _), do: nil
  defp fetch(container, [h]), do: Map.get(container, h)

  defp fetch(container, [h | t]) do
    Map.get(container, h) |> fetch(t)
  end
end
