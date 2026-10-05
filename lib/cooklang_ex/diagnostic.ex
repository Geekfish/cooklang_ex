defmodule CooklangEx.Diagnostic do
  @moduledoc """
  An error or a warning that the parser reports for a recipe.

  Each label points at the part of the source that caused the diagnostic.
  The first label is the main location.
  """

  alias CooklangEx.Diagnostic.Label

  @type severity :: :error | :warning

  @type t :: %__MODULE__{
          severity: severity(),
          message: String.t(),
          hints: [String.t()],
          labels: [Label.t()]
        }

  defstruct severity: :error, message: "", hints: [], labels: []

  @doc false
  def from_map(data) when is_map(data) do
    %__MODULE__{
      severity: severity(data["severity"]),
      message: data["message"] || "",
      hints: data["hints"] || [],
      labels: Enum.map(data["labels"] || [], &Label.from_map/1)
    }
  end

  defp severity("warning"), do: :warning
  defp severity(_), do: :error
end

defmodule CooklangEx.Diagnostic.Label do
  @moduledoc """
  A span of the recipe source that a diagnostic points at.

  - `start` and `end` - byte offsets into the source, `end` exclusive
  - `line` and `column` - 1-based position of `start`; `column` counts characters
  - `message` - an optional note about this span
  """

  @type t :: %__MODULE__{
          start: non_neg_integer(),
          end: non_neg_integer(),
          line: pos_integer(),
          column: pos_integer(),
          message: String.t() | nil
        }

  defstruct [:start, :end, :line, :column, :message]

  @doc false
  def from_map(data) when is_map(data) do
    %__MODULE__{
      start: data["start"],
      end: data["end"],
      line: data["line"],
      column: data["column"],
      message: data["message"]
    }
  end
end
