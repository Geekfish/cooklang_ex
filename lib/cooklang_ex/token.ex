defmodule CooklangEx.Token do
  @moduledoc """
  A part of a recipe source, with its kind and its position.

  `CooklangEx.parse/2` returns what a recipe means, but not where each part
  is in the source. A token gives the position of one part, for example an
  ingredient name or a unit, exactly as the cooklang-rs pull parser reads it.
  Code can use the positions to highlight a recipe, to point at a part, or
  to link a part back to the source. See `CooklangEx.tokens/2`.

  - `kind` - what the part is, see `t:kind/0`
  - `start` and `end` - byte offsets into the source, `end` exclusive. They
    skip the whitespace around the part. If cooklang-rs points inside a
    multi-byte character, the binding moves the offset to a character
    boundary, so that a slice is always valid text.
  - `text` - the trimmed name of an ingredient, a cookware item, or a named
    timer. `nil` for other kinds.
  """

  @typedoc """
  The kind of a token.

  A component has one token for the whole component, from its marker to its
  end:

  - `:ingredient` - for example `@salt{1%tsp}`
  - `:cookware` - for example `#pan{}`
  - `:timer` - for example `~{5%min}`

  The parts inside a component have their own tokens:

  - `:modifiers` - the modifier characters, for example `?` in `@?salt{}`
  - `:name` - the name, for example `salt`
  - `:alias` - the alias after `|`, for example `black pepper` in `@pepper|black pepper{}`
  - `:quantity` - the value, for example `1` or `1-2`
  - `:fixed_marker` - the `=` that stops a quantity from scaling
  - `:unit` - the unit after `%`, for example `tsp`
  - `:note` - the note in brackets, for example `cold` in `@milk{}(cold)`

  Other parts of the source:

  - `:metadata_key` and `:metadata_value` - the parts of a `>>` line
  - `:section` - the name of a section, for example `Prep` in `== Prep ==`
  - `:front_matter` - the YAML block, with its `---` lines
  - `:comment` - a `--` comment to the end of the line, or a `[- -]` comment
  """
  @type kind ::
          :ingredient
          | :cookware
          | :timer
          | :modifiers
          | :name
          | :alias
          | :quantity
          | :fixed_marker
          | :unit
          | :note
          | :metadata_key
          | :metadata_value
          | :section
          | :front_matter
          | :comment

  @typedoc "A part of the source, with its kind and byte offsets."
  @type t :: %__MODULE__{
          kind: kind(),
          start: non_neg_integer(),
          end: non_neg_integer(),
          text: String.t() | nil
        }

  defstruct [:kind, :start, :end, :text]

  @kind_names ~w(ingredient cookware timer modifiers name alias quantity fixed_marker unit note
                 metadata_key metadata_value section front_matter comment)

  @doc false
  def from_map(%{"kind" => kind, "start" => start, "end" => end_offset} = data)
      when kind in @kind_names do
    %__MODULE__{
      # The guard allows only known kinds, so `String.to_atom/1` creates no new atoms.
      kind: String.to_atom(kind),
      start: start,
      end: end_offset,
      text: data["text"]
    }
  end
end
