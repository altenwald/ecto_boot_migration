defmodule EctoBootMigration do
  @moduledoc """
  Helper module that can be used to easily ensure that Ecto database was 
  migrated before rest of the application was started.

  ## Rationale

  There are many strategies how to deal with this issue, 
  e.g. see https://github.com/bitwalker/distillery/blob/master/docs/Running%20Migrations.md

  However, if you have any workers that are relying on the DB schema that are 
  launched upon boot with some methods, such as release post_start hooks you 
  can easily enter race condition. Application may crash as these workers will 
  not find tables or columns they expect and it will happen sooner than the 
  post_start hook script will send the commands to the the application process.

  In stateless environments such as Docker it is just sometimes more convenient 
  to perform migration upon boot. This is exactly what this library does.

  By default if any migrations have happened it will kill the application.
  It should be then restarted by any sort of supervisor. It is to avoid cases
  in which some internal Ecto caches are populated with pre-migration data
  or some processes are started due to migration process that will later
  cause issues. This feature can be disabled by passing an argument to
  the migration-related functions.

  Currently it works only with PostgreSQL databases but that will be easy to 
  extend.

  ## Usage

  ```elixir
  defmodule MyApp do
    use Application

    def start(_type, _args) do
      import Supervisor.Spec, warn: false

      unless EctoBootMigration.migrated?(:my_app) do
        children = [
          supervisor(MyApp.Endpoint, []),
          worker(MyApp.Repo, []),
        ]
        Supervisor.start_link(children, [strategy: :one_for_one, name: MyApp.Supervisor])
      end
    end
  end
      ```
  """

  @apps [
    :crypto,
    :ssl,
    :postgrex,
    :ecto
  ]


  @doc """
  Tries to run migrations. 

  Returns `true` if any migrations have happened.

  Returns `false` if no migrations have happened.

  Throws if error occured. 
  """
  @spec migrated?(any, boolean) :: boolean
  def migrated?(app, stop_on_migration \\ true) do
    case migrate(app, stop_on_migration) do
      {:ok, :noop} ->
        false

      {:ok, {:migrated, _}} ->
        true

      {:error, reason} ->
        throw reason
    end
  end


  @doc """
  Tries to run migrations. 

  Returns `{:ok, {:migrated, list_of_migration_ids}}` if any migrations have 
  happened.

  Returns `{:ok, :noop}` if no migrations have happened.

  Returns `{:error, reason}` if error occured. 
  """
  @spec migrate(any, boolean) :: 
    {:ok, :noop} |
    {:ok, {:migrated, [pos_integer]}} |
    {:error, any}
  def migrate(app, stop_on_migration \\ true) do
    IO.puts "[EctoBootMigration] Loading application #{inspect(app)}..."
    loaded? = 
      case Application.load(app) do
        :ok ->
          IO.puts "[EctoBootMigration] Loaded application #{inspect(app)}"
          true

        {:error, {:already_loaded, ^app}} ->
          IO.puts "[EctoBootMigration] Application #{inspect(app)} is already loaded"
          true

        {:error, reason} ->
          IO.puts "[EctoBootMigration] Failed to start the application: reason = #{inspect(reason)}"
          false
      end

    if loaded? do
      # Start apps necessary for executing migrations
      IO.puts "[EctoBootMigration] Starting dependencies..."
      @apps
      |> Enum.each(fn(app) ->
        IO.puts "[EctoBootMigration] Starting dependency: application #{inspect(app)}"
        Application.ensure_all_started(app)
      end)
      IO.puts "[EctoBootMigration] Started dependencies"

      repos = 
        Application.get_env(app, :ecto_repos, [])

      # Start the Repo(s) for app
      IO.puts "[EctoBootMigration] Starting repos..."
      repos
      |> Enum.each(fn(repo) ->
        IO.puts "[EctoBootMigration] Starting repo: #{inspect(repo)}"
        case repo.start_link(pool_size: 1) do
          {:ok, pid} ->
            IO.puts "[EctoBootMigration] Started repo: pid = #{inspect(pid)}"

          {:error, {:already_started, pid}} ->
            IO.puts "[EctoBootMigration] Repo was already started: pid = #{inspect(pid)}"

          {:error, reason} ->
            IO.puts "[EctoBootMigration] Failed to start the repo: reason = #{inspect(reason)}"
        end
      end)
      IO.puts "[EctoBootMigration] Started repos"

      # Run migrations
      IO.puts "[EctoBootMigration] Running migrations"
      migrations =
        repos
        |> Enum.reduce([], fn(repo, acc) ->
          IO.puts "[EctoBootMigration] Running migration: repo #{inspect(repo)}"

          result = Ecto.Migrator.run(repo, migrations_path(repo), :up, all: true)
          IO.puts "[EctoBootMigration] Run migration: result = #{inspect(result)}"
          acc ++ result
        end)
      IO.puts "[EctoBootMigration] Run migrations: count = #{length(migrations)}"

      IO.puts "[EctoBootMigration] Done"

      case migrations do
        [] ->
          {:ok, :noop}

        migrations ->
          if stop_on_migration do
            IO.puts "[EctoBootMigration] Exiting"
            :init.stop()
          else
            {:ok, {:migrated, migrations}}
          end
      end
    else 
      {:error, :not_loaded}
    end
  end


  defp priv_dir(app) do
    "#{:code.priv_dir(app)}"
  end

  defp migrations_path(repo) do
    priv_path_for(repo, "migrations")
  end

  def priv_path_for(repo, filename) do
    app = Keyword.get(repo.config, :otp_app)
    repo_underscore = repo |> Module.split |> List.last |> Macro.underscore
    Path.join([priv_dir(app), repo_underscore, filename])
  end
end