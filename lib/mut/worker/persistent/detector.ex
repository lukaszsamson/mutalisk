defmodule Mut.Worker.Persistent.Detector do
  @moduledoc """
  Detects target-class signatures known to drift under the persistent
  worker, so the host can emit a one-line "consider --worker-type
  mix" warning before the test load step.

  Operates on the sandbox's compiled dependency tree
  (`_build/mut_schema/lib/<app>/ebin`). The persistent worker
  starts every project app at boot — anything that lands in this
  directory is something the worker BEAM will load.

  This is a *heads-up*, not a diagnosis. A clean Ecto setup will
  still trigger the warning; a Mox-using project that already
  knows the limitation will still trigger it. The signal value is
  in catching users who don't yet know there is drift to look for.

  Returns a list of `{atom_signature, message}` pairs. An empty
  list means the persistent worker should boot silently.

  ## Signature catalogue

    * `:mox`     — `Mox.Server` mock-registry leaks across mutants
                   (see `docs/PERSISTENT_WORKER_GUIDE.md`).
    * `:ecto`    — Warm-BEAM contamination of `Ecto.Query` planner
                   and schema metadata caches.
    * `:gettext` — `Gettext.Compiler.__before_compile__/1` fails
                   under non-parallel-compile boot context.

  Designed to be extensible: the catalogue is a flat list of
  `{app_atom, signature_atom, human_message}` tuples. Add new
  rows as new target-class drift surfaces.
  """

  @signatures [
    {:mox, :mox,
     "Mox-class projects: residual cluster/peer-state drift remains after M28's Mox.Server reset hook (3-mutant residual on mox v1.2.0 self-tests)."},
    {:ecto, :ecto,
     "Ecto-class projects: supervisor-init structural drift cannot be closed by reset hooks (M30 finding); use --worker-type mix."},
    {:ecto_sql, :ecto,
     "Ecto-class projects: supervisor-init structural drift cannot be closed by reset hooks (M30 finding); use --worker-type mix."},
    {:gettext, :gettext,
     "Gettext-class projects: persistent worker is unsupported (M31 finding) — Gettext.Compiler.__before_compile__/1 requires a parallel-compile parent context that the persistent test-load step does not provide. Use --worker-type mix."},
    {:mint, :pool,
     "HTTP-client / pool projects: warm BEAM accumulates socket / pool / registry state across mutants (M27 mint v1.8.0 measured 49/250 = 19.6% pool_warm_state drift). Persistent worker is supported but verify outcomes via mix mut.drift if drift matters."},
    {:finch, :pool,
     "HTTP-client / pool projects: warm BEAM accumulates socket / pool / registry state across mutants. Persistent worker is supported but verify outcomes via mix mut.drift."},
    {:nimble_pool, :pool,
     "Pool-class projects: warm BEAM accumulates pool worker / registry state across mutants (M27 nimble_pool v1.1.0 measured 4/28 = 14.3% pool_warm_state drift). Persistent worker is supported but verify outcomes via mix mut.drift."}
  ]

  @typedoc "Detected signature: `{signature_atom, human_message}`."
  @type detection :: {atom(), String.t()}

  @doc """
  Inspect a sandbox's compiled-dep tree and return zero or more
  detected signatures. Each signature is reported at most once
  (multiple matching apps collapse into a single entry).

  The sandbox path is expected to contain
  `_build/mut_schema/lib/<app>/ebin`. If that tree is absent we
  return an empty list — running on a freshly-created sandbox
  before the schema build has compiled deps is not an error.
  """
  @spec detect(Path.t()) :: [detection()]
  def detect(sandbox_path) when is_binary(sandbox_path) do
    apps = loaded_apps_in_sandbox(sandbox_path)
    detect_in_apps(apps)
  end

  @doc """
  Same as `detect/1` but takes an explicit list of app atoms.
  Useful for tests and for callers that already know the loaded
  app set (e.g. via `Application.loaded_applications/0`).
  """
  @spec detect_in_apps([atom()]) :: [detection()]
  def detect_in_apps(apps) when is_list(apps) do
    app_set = MapSet.new(apps)

    @signatures
    |> Enum.filter(fn {app, _sig, _msg} -> MapSet.member?(app_set, app) end)
    |> Enum.uniq_by(fn {_, sig, _} -> sig end)
    |> Enum.map(fn {_, sig, msg} -> {sig, msg} end)
  end

  @doc """
  Format a detection as a single-line stderr-bound warning string.
  No trailing newline (caller adds one if writing to a stream).
  """
  @spec format_warning(detection()) :: String.t()
  def format_warning({_sig, message}) do
    "[mutalisk] Warning: persistent worker detected #{message} " <>
      "Known drift exists for this class — consider --worker-type mix. " <>
      "See docs/PERSISTENT_WORKER_GUIDE.md."
  end

  @doc false
  @spec loaded_apps_in_sandbox(Path.t()) :: [atom()]
  def loaded_apps_in_sandbox(sandbox_path) do
    sandbox_path
    |> Path.join("_build/mut_schema/lib/*/ebin")
    |> Path.wildcard()
    |> Enum.flat_map(&app_atom_from_ebin/1)
  end

  defp app_atom_from_ebin(ebin_path) do
    case Path.wildcard(Path.join(ebin_path, "*.app")) do
      [] ->
        []

      [app_file | _] ->
        case File.cwd!() do
          _ ->
            name = Path.basename(app_file, ".app")
            [String.to_atom(name)]
        end
    end
  end
end
