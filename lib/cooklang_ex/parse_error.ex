defmodule CooklangEx.ParseError do
  @moduledoc """
  The error that `CooklangEx.parse/2` and `CooklangEx.parse_and_scale/3` return
  when a recipe cannot be parsed.

  `message` joins the messages of all diagnostics with newlines.
  `diagnostics` holds each error with its position in the source.
  An error that has no position, for example a scaling error, has no diagnostics.
  """

  alias CooklangEx.Diagnostic

  @type t :: %__MODULE__{
          message: String.t(),
          diagnostics: [Diagnostic.t()]
        }

  defexception message: "", diagnostics: []

  @doc false
  def from_json(json_string) when is_binary(json_string) do
    data = Jason.decode!(json_string)

    %__MODULE__{
      message: data["message"] || "",
      diagnostics: Enum.map(data["diagnostics"] || [], &Diagnostic.from_map/1)
    }
  end
end
