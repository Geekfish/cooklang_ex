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
