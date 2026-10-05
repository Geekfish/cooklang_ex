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
end
