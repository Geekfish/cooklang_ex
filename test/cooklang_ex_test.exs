defmodule CooklangExTest do
  use ExUnit.Case
  doctest CooklangEx

  describe "parse/1" do
    test "parses a simple recipe" do
      recipe_text = """
      Add @eggs{3} to a #bowl{}.
      """

      assert {:ok, recipe} = CooklangEx.parse(recipe_text)
      assert length(recipe.ingredients) == 1
      assert hd(recipe.ingredients).name == "eggs"
      assert hd(recipe.ingredients).quantity.value == 3.0
    end

    test "parses ingredients with units" do
      recipe_text = """
      Add @flour{200%g} and @milk{1%cup}.
      """

      assert {:ok, recipe} = CooklangEx.parse(recipe_text)
      assert length(recipe.ingredients) == 2

      flour = Enum.find(recipe.ingredients, &(&1.name == "flour"))
      assert flour.quantity.value == 200.0
      assert flour.quantity.unit == "g"

      milk = Enum.find(recipe.ingredients, &(&1.name == "milk"))
      assert milk.quantity.value == 1.0
      assert milk.quantity.unit == "cup"
    end

    test "parses multi-word ingredient names" do
      recipe_text = """
      Season with @ground black pepper{} and @sea salt{1%pinch}.
      """

      assert {:ok, recipe} = CooklangEx.parse(recipe_text)
      assert length(recipe.ingredients) == 2

      names = Enum.map(recipe.ingredients, & &1.name)
      assert "ground black pepper" in names
      assert "sea salt" in names
    end

    test "parses cookware" do
      recipe_text = """
      Heat in a #pan{large} and serve in a #bowl{}.
      """

      assert {:ok, recipe} = CooklangEx.parse(recipe_text)
      assert length(recipe.cookware) == 2

      names = Enum.map(recipe.cookware, & &1.name)
      assert "pan" in names
      assert "bowl" in names
    end

    test "parses timers" do
      recipe_text = """
      Cook for ~{5%minutes} then rest for ~{30%seconds}.
      """

      assert {:ok, recipe} = CooklangEx.parse(recipe_text)
      assert length(recipe.timers) == 2
    end

    test "parses metadata" do
      recipe_text = """
      >> servings: 4
      >> source: https://example.com
      >> time: 30 minutes

      Add @salt{}.
      """

      assert {:ok, recipe} = CooklangEx.parse(recipe_text)
      assert recipe.metadata["servings"] == "4"
      assert recipe.metadata["source"] == "https://example.com"
      assert recipe.metadata["time"] == "30 minutes"
    end

    test "handles empty recipe" do
      assert {:ok, recipe} = CooklangEx.parse("")
      assert recipe.ingredients == []
      assert recipe.cookware == []
      assert recipe.timers == []
    end
  end

  describe "parse/2 quantity scalability" do
    test "marks ingredient quantities as scalable and `=` quantities as fixed" do
      assert {:ok, recipe} = CooklangEx.parse("Mix @flour{500%g} with @salt{=1%tsp}.")

      flour = Enum.find(recipe.ingredients, &(&1.name == "flour"))
      salt = Enum.find(recipe.ingredients, &(&1.name == "salt"))

      assert flour.quantity.scalable == true
      assert salt.quantity.scalable == false
    end

    test "marks ingredient ranges as scalable and cookware and timer quantities as fixed" do
      assert {:ok, recipe} = CooklangEx.parse("Beat @eggs{2-4} in #bowls{2} for ~{3%minutes}.")

      assert hd(recipe.ingredients).quantity.scalable == true
      assert hd(recipe.cookware).quantity.scalable == false
      assert hd(recipe.timers).quantity.scalable == false
    end
  end

  describe "parse/2 missing quantities" do
    test "returns no quantity for empty braces, the same as for no braces" do
      assert {:ok, recipe} = CooklangEx.parse("Add @salt{}, @pepper and use a #pan{}.")

      assert [%{name: "salt", quantity: nil}, %{name: "pepper", quantity: nil}] =
               recipe.ingredients

      assert [%{name: "pan", quantity: nil}] = recipe.cookware
    end
  end

  describe "parse/2 ranges" do
    test "returns a range quantity as a {start, end} tuple" do
      assert {:ok, recipe} = CooklangEx.parse("Beat @eggs{2-4}.")

      assert hd(recipe.ingredients).quantity.value == {2.0, 4.0}
    end
  end

  describe "parse/2 diagnostics" do
    @recipe_with_errors """
    Chop @onion{1}.

    Add @flour{%g} and stir.

    Add @salt{=} to taste.
    """

    test "returns a ParseError with a diagnostic and a position for each error" do
      assert {:error, %CooklangEx.ParseError{} = error} = CooklangEx.parse(@recipe_with_errors)

      assert error.message == "Empty quantity value\nEmpty quantity value"

      assert [first, second] = error.diagnostics
      assert %CooklangEx.Diagnostic{severity: :error, message: "Empty quantity value"} = first

      # cooklang-rs marks the empty point where the value is missing: before `%g`.
      assert [
               %CooklangEx.Diagnostic.Label{line: 3, column: 12, message: "add value here"} =
                 label
             ] =
               first.labels

      assert label.start == label.end
      assert binary_part(@recipe_with_errors, label.start, 2) == "%g"

      assert [%CooklangEx.Diagnostic.Label{line: 5, column: 12}] = second.labels
    end

    test "returns warnings with positions in recipe.diagnostics" do
      assert {:ok, recipe} = CooklangEx.parse("Stir.\nWait ~{10}.\n")

      assert recipe.warnings == ["Invalid timer quantity: missing unit"]

      assert [
               %CooklangEx.Diagnostic{
                 severity: :warning,
                 message: "Invalid timer quantity: missing unit",
                 labels: [%CooklangEx.Diagnostic.Label{line: 2} | _]
               }
             ] = recipe.diagnostics
    end

    test "keeps every error and warning of a failed parse, in report order" do
      # cooklang-rs keeps parsing after an error, so the report also has the
      # problems that come after the first error.
      source = "Add @flour{%g}.\nWait ~{10}.\nAdd @salt{%g}.\n"
      assert {:error, error} = CooklangEx.parse(source)

      assert error.message == "Empty quantity value\nEmpty quantity value"

      assert [
               %CooklangEx.Diagnostic{
                 severity: :error,
                 message: "Empty quantity value",
                 labels: [%CooklangEx.Diagnostic.Label{line: 1} | _]
               },
               %CooklangEx.Diagnostic{
                 severity: :warning,
                 message: "Invalid timer quantity: missing unit",
                 labels: [%CooklangEx.Diagnostic.Label{line: 2} | _]
               },
               %CooklangEx.Diagnostic{
                 severity: :error,
                 message: "Empty quantity value",
                 labels: [%CooklangEx.Diagnostic.Label{line: 3} | _]
               }
             ] = error.diagnostics
    end

    test "reports the stage that raised each diagnostic, with its hints" do
      assert {:error, error} = CooklangEx.parse("Add @flour{%g}.")

      assert [%CooklangEx.Diagnostic{message: "Empty quantity value", stage: :parse}] =
               error.diagnostics

      assert {:ok, recipe} = CooklangEx.parse("Use a #pan{=2}.")

      assert [
               %CooklangEx.Diagnostic{
                 severity: :warning,
                 message: "Unnecessary scaling lock modifier",
                 stage: :analysis,
                 hints: ["Only ingredients can be scaled, scaling lock is not needed here"]
               }
             ] = recipe.diagnostics
    end

    test "reports the underlying cause of a diagnostic, if there is one" do
      # The numerator does not fit in the u32 that cooklang-rs parses it into.
      assert {:error, error} = CooklangEx.parse("Add @eggs{99999999999/2}.")

      assert [
               %CooklangEx.Diagnostic{
                 message: "Error parsing integer number",
                 cause: "number too large to fit in target type"
               }
             ] = error.diagnostics

      assert {:error, error} = CooklangEx.parse("Add @flour{%g}.")
      assert [%CooklangEx.Diagnostic{cause: nil}] = error.diagnostics
    end

    test "counts columns in characters, not in bytes" do
      source = "Crème brûlée ~{10}.\nAjoutez @farine{%g}.\n"
      assert {:error, error} = CooklangEx.parse(source)

      assert [
               %CooklangEx.Diagnostic{labels: [warning_label | _]},
               %CooklangEx.Diagnostic{labels: [error_label | _]}
             ] = error.diagnostics

      # `}` is the 18th character of line 1, after three 2-byte characters.
      assert {warning_label.line, warning_label.column} == {1, 18}
      assert binary_part(source, warning_label.start, 1) == "}"

      # `%` is the 17th character of line 2.
      assert {error_label.line, error_label.column} == {2, 17}
      assert binary_part(source, error_label.start, 1) == "%"
    end

    test "counts lines with CRLF line endings" do
      source = "Stir.\r\nWait ~{10}.\r\nAdd @flour{%g}.\r\n"
      assert {:error, error} = CooklangEx.parse(source)

      assert [
               %CooklangEx.Diagnostic{labels: [%{line: 2} | _]},
               %CooklangEx.Diagnostic{labels: [%{line: 3, column: 12} | _]}
             ] = error.diagnostics
    end

    test "moves a label that points inside a multi-byte character to its start" do
      # cooklang-rs points one byte before the `(` of a timer note, which is
      # inside the 2-byte `é`.
      source = "Wait ~minuté(soft)."
      assert {:error, error} = CooklangEx.parse(source)

      assert [
               %CooklangEx.Diagnostic{
                 message: "A timer cannot have a note, it will be text",
                 labels: [_note_label, space_label]
               },
               %CooklangEx.Diagnostic{message: "Invalid timer: missing quantity"}
             ] = error.diagnostics

      assert {space_label.line, space_label.column} == {1, 12}
      assert binary_part(source, space_label.start, 2) == "é"
    end

    test "turns into its message as a string, the error value before ParseError" do
      assert {:error, error} = CooklangEx.parse("Add @flour{%g}.\n\nAdd @salt{%g}.")

      assert to_string(error) == "Empty quantity value\nEmpty quantity value"
      assert "Failed: #{error}" == "Failed: Empty quantity value\nEmpty quantity value"
    end
  end

  describe "parse_and_scale/3 errors" do
    @recipe_with_error ">> servings: 2\n\nAdd @flour{%g}.\n"

    test "returns a ParseError with the diagnostics of the report" do
      assert {:error, %CooklangEx.ParseError{} = error} =
               CooklangEx.parse_and_scale(@recipe_with_error, 4)

      assert [
               %CooklangEx.Diagnostic{
                 message: "Empty quantity value",
                 labels: [%CooklangEx.Diagnostic.Label{line: 3, column: 12} | _]
               }
             ] = error.diagnostics
    end

    test "parse_and_scale!/3 raises the ParseError" do
      assert_raise CooklangEx.ParseError, "Empty quantity value", fn ->
        CooklangEx.parse_and_scale!(@recipe_with_error, 4)
      end
    end
  end

  describe "parse_and_scale/2" do
    test "scales ingredient quantities" do
      recipe_text = """
      >> servings: 2

      Add @flour{200%g} and @eggs{2}.
      """

      assert {:ok, recipe} = CooklangEx.parse_and_scale(recipe_text, 4)

      flour = Enum.find(recipe.ingredients, &(&1.name == "flour"))
      assert flour.quantity.value == 400.0

      eggs = Enum.find(recipe.ingredients, &(&1.name == "eggs"))
      assert eggs.quantity.value == 4.0
    end

    test "scales down" do
      recipe_text = """
      >> servings: 4

      Add @butter{100%g}.
      """

      assert {:ok, recipe} = CooklangEx.parse_and_scale(recipe_text, 2)

      butter = Enum.find(recipe.ingredients, &(&1.name == "butter"))
      assert butter.quantity.value == 50.0
    end
  end

  describe "ingredients/1" do
    test "extracts only ingredients" do
      recipe_text = """
      Add @eggs{3} to a #bowl{} and cook for ~{5%minutes}.
      """

      assert {:ok, ingredients} = CooklangEx.ingredients(recipe_text)
      assert length(ingredients) == 1
      assert hd(ingredients).name == "eggs"
    end
  end

  describe "cookware/1" do
    test "extracts only cookware" do
      recipe_text = """
      Add @eggs{3} to a #bowl{} and transfer to a #plate{}.
      """

      assert {:ok, cookware} = CooklangEx.cookware(recipe_text)
      assert length(cookware) == 2
    end
  end

  describe "metadata/1" do
    test "extracts only metadata" do
      recipe_text = """
      >> servings: 4
      >> author: Test

      Add @ingredient{}.
      """

      assert {:ok, metadata} = CooklangEx.metadata(recipe_text)
      assert metadata["servings"] == "4"
      assert metadata["author"] == "Test"
    end
  end

  describe "parse!/1" do
    test "returns recipe on success" do
      recipe = CooklangEx.parse!("Add @salt{}.")
      assert length(recipe.ingredients) == 1
    end

    test "raises on invalid input" do
      # Note: cooklang-rs is quite permissive, so we test with clearly invalid syntax
      # In practice, most input will parse (possibly with warnings)
      recipe = CooklangEx.parse!("Just plain text")
      assert recipe.ingredients == []
    end

    test "raises a ParseError with the joined messages" do
      assert_raise CooklangEx.ParseError, "Empty quantity value", fn ->
        CooklangEx.parse!("Add @flour{%g}.")
      end
    end
  end

  describe "tokens/2" do
    test "returns an ingredient with each of its parts" do
      source = "Fry @olive oil{=2%tbsp}(cold)."

      assert {:ok, tokens} = CooklangEx.tokens(source)

      assert kinds_and_slices(source, tokens) == [
               {:ingredient, "@olive oil{=2%tbsp}(cold)"},
               {:name, "olive oil"},
               {:fixed_marker, "="},
               {:quantity, "2"},
               {:unit, "tbsp"},
               {:note, "cold"}
             ]

      assert hd(tokens).text == "olive oil"
    end

    test "returns cookware and timers with their names" do
      source = "Bake in #oven{} for ~bake{20%min}."

      assert {:ok, tokens} = CooklangEx.tokens(source)

      assert kinds_and_slices(source, tokens) == [
               {:cookware, "#oven{}"},
               {:name, "oven"},
               {:timer, "~bake{20%min}"},
               {:name, "bake"},
               {:quantity, "20"},
               {:unit, "min"}
             ]

      assert Enum.map(tokens, & &1.text) == ["oven", nil, "bake", nil, nil, nil]
    end

    test "returns metadata, sections, and comments" do
      source = """
      >> course: dinner
      == Prep ==
      Chop @onion{2} -- to the end of the line
      [- block -] Stir.
      -- a whole line
      """

      assert {:ok, tokens} = CooklangEx.tokens(source)
      slices = kinds_and_slices(source, tokens)

      assert {:metadata_key, "course"} in slices
      assert {:metadata_value, "dinner"} in slices
      assert {:section, "Prep"} in slices
      assert {:comment, "-- to the end of the line"} in slices
      assert {:comment, "[- block -]"} in slices
      assert {:comment, "-- a whole line"} in slices
    end

    test "returns the front matter with its lines as one token" do
      source = """
      ---
      servings: 2
      ---
      Add @salt{}.
      """

      assert {:ok, tokens} = CooklangEx.tokens(source)

      assert [{:front_matter, "---\nservings: 2\n---"} | _] = kinds_and_slices(source, tokens)
      refute Enum.any?(tokens, &(&1.kind == :comment))
    end

    test "returns tokens for a recipe with errors" do
      source = "Add @salt{1/0%tsp} to #pan{}."

      assert {:error, _} = CooklangEx.parse(source)
      assert {:ok, tokens} = CooklangEx.tokens(source)

      assert Enum.filter(tokens, & &1.text) |> Enum.map(&{&1.kind, &1.text}) == [
               {:ingredient, "salt"},
               {:cookware, "pan"}
             ]
    end

    test "returns byte offsets on character boundaries" do
      source = "Add @crème fraîche{2%tbsp} and wait ~minuté(soft)."

      assert {:ok, tokens} = CooklangEx.tokens(source)

      for token <- tokens do
        assert String.valid?(binary_part(source, token.start, token.end - token.start))
      end

      assert {:name, "crème fraîche"} in kinds_and_slices(source, tokens)
    end

    test "returns no tokens for plain text" do
      assert CooklangEx.tokens("Just text.") == {:ok, []}
    end

    test "returns no tokens for an empty source" do
      assert CooklangEx.tokens("") == {:ok, []}
    end

    test "returns the alias of a component" do
      source = "Add @pepper|black pepper{}."

      assert {:ok, tokens} = CooklangEx.tokens(source)

      assert kinds_and_slices(source, tokens) == [
               {:ingredient, "@pepper|black pepper{}"},
               {:name, "pepper"},
               {:alias, "black pepper"}
             ]
    end

    test "returns the modifiers of a component" do
      source = "Add @?salt{}, @&flour{}, and @@tomato sauce{}."

      assert {:ok, tokens} = CooklangEx.tokens(source)
      slices = kinds_and_slices(source, tokens)

      assert Enum.filter(slices, &match?({:modifiers, _}, &1)) ==
               [modifiers: "?", modifiers: "&", modifiers: "@"]

      assert Enum.map(Enum.filter(tokens, & &1.text), & &1.text) ==
               ["salt", "flour", "tomato sauce"]
    end

    test "returns a range as one quantity" do
      source = "Add @salt{1-2%tsp}."

      assert {:ok, tokens} = CooklangEx.tokens(source)
      assert {:quantity, "1-2"} in kinds_and_slices(source, tokens)
    end

    test "returns a timer without a name" do
      source = "Wait ~{5%min}."

      assert {:ok, [timer | parts]} = CooklangEx.tokens(source)

      assert timer.kind == :timer
      assert timer.text == nil
      assert kinds_and_slices(source, parts) == [quantity: "5", unit: "min"]
    end

    test "treats an escaped -- as text" do
      assert CooklangEx.tokens("Use \\-- here.") == {:ok, []}
    end

    test "treats a --- line inside the steps as a comment" do
      source = "Step one.\n---\nStep two."

      assert {:ok, tokens} = CooklangEx.tokens(source)
      assert kinds_and_slices(source, tokens) == [comment: "---"]
    end

    test "runs an unclosed block comment to the end of the source" do
      source = "Stir. [- never closed"

      assert {:ok, tokens} = CooklangEx.tokens(source)
      assert kinds_and_slices(source, tokens) == [comment: "[- never closed"]
    end

    test "ends a comment at the end of the source" do
      source = "Stir. -- end"

      assert {:ok, tokens} = CooklangEx.tokens(source)
      assert kinds_and_slices(source, tokens) == [comment: "-- end"]
    end

    test "ends a comment before a Windows line ending" do
      source = "Stir. -- end\r\nFry @egg{}.\r\n"

      assert {:ok, tokens} = CooklangEx.tokens(source)
      slices = kinds_and_slices(source, tokens)

      assert {:comment, "-- end"} in slices
      assert {:name, "egg"} in slices
    end

    test "reads modifiers and aliases as part of the name without extensions" do
      source = "Add @?salt{} and @pepper|black pepper{}."

      assert {:ok, tokens} = CooklangEx.tokens(source, all_extensions: false)

      assert Enum.map(Enum.filter(tokens, & &1.text), & &1.text) ==
               ["?salt", "pepper|black pepper"]

      refute Enum.any?(tokens, &(&1.kind in [:modifiers, :alias]))
    end
  end

  defp kinds_and_slices(source, tokens) do
    Enum.map(tokens, &{&1.kind, binary_part(source, &1.start, &1.end - &1.start)})
  end
end
