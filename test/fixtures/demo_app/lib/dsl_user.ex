defmodule DslUser do
  @moduledoc "Fixture DSL user module."

  require DslDef

  DslDef.defadd(:sum)
  DslDef.defadd_keep(:sum_keep)
end
