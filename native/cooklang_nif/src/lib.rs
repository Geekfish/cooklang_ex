//! Cooklang NIF bindings for Elixir
//!
//! This crate provides Rustler-based NIF functions that wrap the cooklang-rs parser,
//! enabling Elixir applications to parse Cooklang recipes with full feature support.

use cooklang::error::{SourceDiag, SourceReport, Stage};
use cooklang::model::Recipe;
use cooklang::parser::{self, Event, PullParser};
use cooklang::{Converter, CooklangParser, Extensions, Located, Span};
use serde::Serialize;
use std::collections::HashMap;

rustler::init!("Elixir.CooklangEx.Native");

// ============================================================================
// Serializable output types
// ============================================================================

#[derive(Serialize)]
struct RecipeOutput {
    metadata: HashMap<String, String>,
    ingredients: Vec<IngredientOutput>,
    cookware: Vec<CookwareOutput>,
    timers: Vec<TimerOutput>,
    sections: Vec<SectionOutput>,
    warnings: Vec<String>,
    diagnostics: Vec<DiagnosticOutput>,
}

#[derive(Serialize)]
struct IngredientOutput {
    name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    quantity: Option<QuantityOutput>,
    #[serde(skip_serializing_if = "Option::is_none")]
    note: Option<String>,
}

#[derive(Serialize)]
struct CookwareOutput {
    name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    quantity: Option<QuantityOutput>,
    #[serde(skip_serializing_if = "Option::is_none")]
    note: Option<String>,
}

#[derive(Serialize)]
struct TimerOutput {
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    quantity: Option<QuantityOutput>,
}

#[derive(Serialize)]
struct QuantityOutput {
    #[serde(skip_serializing_if = "Option::is_none")]
    value: Option<ValueOutput>,
    #[serde(skip_serializing_if = "Option::is_none")]
    unit: Option<String>,
    scalable: bool,
}

#[derive(Serialize)]
#[serde(untagged)]
enum ValueOutput {
    Number(f64),
    Text(String),
    Range { start: f64, end: f64 },
}

#[derive(Serialize)]
struct ParseErrorOutput {
    message: String,
    diagnostics: Vec<DiagnosticOutput>,
}

#[derive(Serialize)]
struct DiagnosticOutput {
    severity: &'static str,
    stage: &'static str,
    message: String,
    /// The lower-level error behind the diagnostic, if cooklang-rs has one.
    #[serde(skip_serializing_if = "Option::is_none")]
    cause: Option<String>,
    hints: Vec<String>,
    labels: Vec<LabelOutput>,
}

/// A labelled span of the source. `start` and `end` are byte offsets.
/// `line` and `column` are 1-based, and `column` counts characters.
#[derive(Serialize)]
struct LabelOutput {
    start: usize,
    end: usize,
    line: usize,
    column: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    message: Option<String>,
}

#[derive(Serialize)]
struct SectionOutput {
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<String>,
    content: Vec<StepOutput>,
}

#[derive(Serialize)]
struct StepOutput {
    items: Vec<ItemOutput>,
}

#[derive(Serialize)]
#[serde(tag = "type")]
enum ItemOutput {
    #[serde(rename = "text")]
    Text { value: String },
    #[serde(rename = "ingredient")]
    Ingredient { index: usize },
    #[serde(rename = "cookware")]
    Cookware { index: usize },
    #[serde(rename = "timer")]
    Timer { index: usize },
}

/// A part of the source with its kind. `start` and `end` are byte offsets.
#[derive(Serialize)]
struct TokenOutput {
    kind: &'static str,
    start: usize,
    end: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    text: Option<String>,
}

// ============================================================================
// NIF Functions
// ============================================================================

/// Parse a Cooklang recipe string.
///
/// Returns `{:ok, json_string}` on success or `{:error, message}` on failure.
#[rustler::nif(schedule = "DirtyCpu")]
fn parse(input: &str, all_extensions: bool) -> Result<String, String> {
    let extensions = if all_extensions {
        Extensions::all()
    } else {
        Extensions::empty()
    };

    let parser = CooklangParser::new(extensions, Converter::default());

    match parser.parse(input).into_result() {
        Ok((recipe, report)) => {
            let output = convert_recipe(&recipe, &report, input);
            let json = serde_json::to_string(&output)
                .map_err(|e| message_error_json(format!("JSON serialization error: {}", e)))?;
            Ok(json)
        }
        Err(report) => Err(error_json(&report, input)),
    }
}

/// Parse and scale a Cooklang recipe to a target number of servings.
///
/// The recipe must have a `servings` metadata field.
/// Returns `{:ok, json_string}` on success or `{:error, message}` on failure.
#[rustler::nif(schedule = "DirtyCpu")]
fn parse_and_scale(
    input: &str,
    target_servings: u32,
    all_extensions: bool,
) -> Result<String, String> {
    let extensions = if all_extensions {
        Extensions::all()
    } else {
        Extensions::empty()
    };

    let parser = CooklangParser::new(extensions, Converter::default());

    match parser.parse(input).into_result() {
        Ok((recipe, report)) => {
            // Clone the recipe and scale it in place
            let mut scaled_recipe = recipe.clone();
            scaled_recipe
                .scale_to_servings(target_servings, parser.converter())
                .map_err(|e| message_error_json(format!("Scaling error: {}", e)))?;

            let output = convert_recipe(&scaled_recipe, &report, input);
            let json = serde_json::to_string(&output)
                .map_err(|e| message_error_json(format!("JSON serialization error: {}", e)))?;
            Ok(json)
        }
        Err(report) => Err(error_json(&report, input)),
    }
}

/// Parse a Cooklang aisle configuration file.
///
/// Returns `{:ok, json_string}` on success or `{:error, message}` on failure.
#[rustler::nif]
fn parse_aisle_config(input: &str) -> Result<String, String> {
    match cooklang::aisle::parse(input) {
        Ok(config) => {
            let json = serde_json::to_string(&config)
                .map_err(|e| format!("JSON serialization error: {}", e))?;
            Ok(json)
        }
        Err(e) => Err(e.to_string()),
    }
}

/// Split a Cooklang recipe string into tokens, with the kind and byte
/// offsets of each part.
///
/// The tokens come from the pull parser, which recovers from errors, so a
/// recipe with errors still has tokens.
/// Returns `{:ok, json_string}` on success or `{:error, message}` on failure.
#[rustler::nif]
fn tokens(input: &str, all_extensions: bool) -> Result<String, String> {
    let extensions = if all_extensions {
        Extensions::all()
    } else {
        Extensions::empty()
    };

    let output = Tokenizer::new(input).run(extensions);
    serde_json::to_string(&output).map_err(|e| format!("JSON serialization error: {}", e))
}

// ============================================================================
// Tokens
// ============================================================================

/// Collects the tokens of one source. `covered` marks each byte that an event
/// accounts for. The parser emits no event for a comment, so the comments are
/// in the bytes that stay uncovered.
struct Tokenizer<'i> {
    input: &'i str,
    tokens: Vec<TokenOutput>,
    covered: Vec<bool>,
}

impl<'i> Tokenizer<'i> {
    fn new(input: &'i str) -> Self {
        Self {
            input,
            tokens: Vec::new(),
            covered: vec![false; input.len()],
        }
    }

    fn run(mut self, extensions: Extensions) -> Vec<TokenOutput> {
        for event in PullParser::new(self.input, extensions) {
            match event {
                Event::YAMLFrontMatter(text) => self.front_matter(text.span()),
                Event::Metadata { key, value } => {
                    self.push("metadata_key", key.span(), None);
                    self.push("metadata_value", value.span(), None);
                    self.cover(key.span());
                    self.cover(value.span());
                }
                Event::Section { name: Some(name) } => {
                    self.push("section", name.span(), None);
                    self.cover(name.span());
                }
                Event::Text(text) => {
                    for fragment in text.fragments() {
                        self.cover(fragment.span());
                    }
                }
                Event::Ingredient(ingredient) => self.ingredient(&ingredient),
                Event::Cookware(cookware) => self.cookware(&cookware),
                Event::Timer(timer) => self.timer(&timer),
                _ => {}
            }
        }

        self.comments();
        // A component comes before the parts inside it.
        self.tokens
            .sort_by_key(|token| (token.start, std::cmp::Reverse(token.end)));
        self.tokens
    }

    /// The YAML front matter, with the `---` lines around it.
    fn front_matter(&mut self, span: Span) {
        let end = self.input[span.end()..]
            .find('\n')
            .map_or(self.input.len(), |offset| span.end() + offset);
        let block = Span::from(0..end);
        self.push("front_matter", block, None);
        self.cover(block);
    }

    fn ingredient(&mut self, ingredient: &Located<parser::Ingredient>) {
        let name = ingredient.name.text_trimmed().into_owned();
        self.push("ingredient", ingredient.span(), Some(name));
        self.push("modifiers", ingredient.modifiers.span(), None);
        self.push("name", ingredient.name.span(), None);
        self.optional("alias", ingredient.alias.as_ref().map(|alias| alias.span()));
        self.quantity(ingredient.quantity.as_ref());
        self.optional("note", ingredient.note.as_ref().map(|note| note.span()));
        self.cover(ingredient.span());
    }

    fn cookware(&mut self, cookware: &Located<parser::Cookware>) {
        let name = cookware.name.text_trimmed().into_owned();
        self.push("cookware", cookware.span(), Some(name));
        self.push("modifiers", cookware.modifiers.span(), None);
        self.push("name", cookware.name.span(), None);
        self.optional("alias", cookware.alias.as_ref().map(|alias| alias.span()));
        self.quantity(cookware.quantity.as_ref());
        self.optional("note", cookware.note.as_ref().map(|note| note.span()));
        self.cover(cookware.span());
    }

    fn timer(&mut self, timer: &Located<parser::Timer>) {
        let name = timer
            .name
            .as_ref()
            .map(|name| name.text_trimmed().into_owned());
        self.push("timer", timer.span(), name);
        self.optional("name", timer.name.as_ref().map(|name| name.span()));
        self.quantity(timer.quantity.as_ref());
        self.cover(timer.span());
    }

    fn quantity(&mut self, quantity: Option<&Located<parser::Quantity>>) {
        if let Some(quantity) = quantity {
            self.push("quantity", quantity.value.span(), None);
            self.optional("fixed_marker", quantity.value.scaling_lock);
            self.optional("unit", quantity.unit.as_ref().map(|unit| unit.span()));
        }
    }

    /// A `--` comment runs to the end of the line. A `[- -]` comment runs to
    /// its closing `-]`. Both markers are ASCII, so each slice is valid text.
    fn comments(&mut self) {
        let bytes = self.input.as_bytes();
        let mut index = 0;

        while index + 1 < bytes.len() {
            if self.covered[index] || self.covered[index + 1] {
                index += 1;
                continue;
            }

            let end = match (bytes[index], bytes[index + 1]) {
                (b'-', b'-') => self.input[index..]
                    .find('\n')
                    .map_or(bytes.len(), |offset| index + offset),
                (b'[', b'-') => self.input[index + 2..]
                    .find("-]")
                    .map_or(bytes.len(), |offset| index + 2 + offset + 2),
                _ => {
                    index += 1;
                    continue;
                }
            };

            self.push("comment", Span::from(index..end), None);
            index = end;
        }
    }

    fn optional(&mut self, kind: &'static str, span: Option<Span>) {
        if let Some(span) = span {
            self.push(kind, span, None);
        }
    }

    /// Adds a token without the whitespace around it, unless it is empty. If
    /// cooklang-rs points inside a multi-byte character, the offsets move to
    /// character boundaries. Some spans include the spaces around a name, for
    /// example the key of `>> course: dinner`.
    fn push(&mut self, kind: &'static str, span: Span, text: Option<String>) {
        let start = floor_char_boundary(self.input, span.start());
        let end = ceil_char_boundary(self.input, span.end()).max(start);
        let slice = &self.input[start..end];
        let end = start + slice.trim_end().len();
        let start = end - slice.trim().len();

        if start < end {
            self.tokens.push(TokenOutput {
                kind,
                start,
                end,
                text,
            });
        }
    }

    fn cover(&mut self, span: Span) {
        let end = span.end().min(self.covered.len());
        let start = span.start().min(end);
        self.covered[start..end].fill(true);
    }
}

/// The largest character boundary of `input` at or before `offset`.
fn floor_char_boundary(input: &str, offset: usize) -> usize {
    let mut offset = offset.min(input.len());
    while !input.is_char_boundary(offset) {
        offset -= 1;
    }
    offset
}

/// The smallest character boundary of `input` at or after `offset`.
fn ceil_char_boundary(input: &str, offset: usize) -> usize {
    let mut offset = offset.min(input.len());
    while !input.is_char_boundary(offset) {
        offset += 1;
    }
    offset
}

// ============================================================================
// Conversion helpers
// ============================================================================

/// JSON for the `{:error, json}` result of a failed parse.
///
/// `diagnostics` holds the whole report, errors and warnings, in report order.
/// `message` joins the error messages only.
fn error_json(report: &SourceReport, input: &str) -> String {
    let diagnostics: Vec<DiagnosticOutput> = report
        .iter()
        .map(|diag| convert_diagnostic(diag, input))
        .collect();

    let message = report
        .errors()
        .map(|diag| diag.message.to_string())
        .collect::<Vec<_>>()
        .join("\n");

    to_json(&ParseErrorOutput {
        message,
        diagnostics,
    })
}

/// JSON for an error that has no position in the source.
fn message_error_json(message: String) -> String {
    to_json(&ParseErrorOutput {
        message,
        diagnostics: vec![],
    })
}

fn to_json(error: &ParseErrorOutput) -> String {
    serde_json::to_string(error).unwrap_or_else(|e| {
        format!(
            r#"{{"message":"JSON serialization error: {}","diagnostics":[]}}"#,
            e.to_string().replace('"', "'")
        )
    })
}

fn convert_diagnostic(diag: &SourceDiag, input: &str) -> DiagnosticOutput {
    DiagnosticOutput {
        severity: if diag.is_error() { "error" } else { "warning" },
        stage: match diag.stage {
            Stage::Parse => "parse",
            Stage::Analysis => "analysis",
        },
        message: diag.message.to_string(),
        cause: std::error::Error::source(diag).map(|cause| cause.to_string()),
        hints: diag.hints.iter().map(|h| h.to_string()).collect(),
        labels: diag
            .labels
            .iter()
            .map(|(span, message)| {
                // cooklang-rs can point inside a multi-byte character, for
                // example one byte before the `(` of a timer note after `é`.
                // Move the offsets to character boundaries, so that slicing
                // the source with them gives valid text.
                let start = floor_char_boundary(input, span.start());
                let end = ceil_char_boundary(input, span.end()).max(start);
                let (line, column) = line_and_column(input, start);
                LabelOutput {
                    start,
                    end,
                    line,
                    column,
                    message: message.as_ref().map(|m| m.to_string()),
                }
            })
            .collect(),
    }
}

/// 1-based line and character column of a byte offset in `input`.
/// `offset` must be a character boundary.
fn line_and_column(input: &str, offset: usize) -> (usize, usize) {
    let before = &input[..offset];
    let line = before.matches('\n').count() + 1;
    let line_start = before.rfind('\n').map_or(0, |i| i + 1);
    let column = before[line_start..].chars().count() + 1;
    (line, column)
}

fn convert_recipe(recipe: &Recipe, report: &SourceReport, input: &str) -> RecipeOutput {
    let metadata: HashMap<String, String> = recipe
        .metadata
        .map
        .iter()
        .map(|(k, v)| {
            let key = k.as_str().unwrap_or("").to_string();
            let value = v.as_str().unwrap_or("").to_string();
            (key, value)
        })
        .collect();

    let ingredients: Vec<IngredientOutput> = recipe
        .ingredients
        .iter()
        .map(|ing| IngredientOutput {
            name: ing.name.clone(),
            quantity: ing.quantity.as_ref().map(convert_quantity),
            note: ing.note.clone(),
        })
        .collect();

    let cookware: Vec<CookwareOutput> = recipe
        .cookware
        .iter()
        .map(|cw| CookwareOutput {
            name: cw.name.clone(),
            quantity: cw.quantity.as_ref().map(convert_quantity),
            note: cw.note.clone(),
        })
        .collect();

    let timers: Vec<TimerOutput> = recipe
        .timers
        .iter()
        .map(|t| TimerOutput {
            name: t.name.clone(),
            quantity: t.quantity.as_ref().map(convert_quantity),
        })
        .collect();

    let sections: Vec<SectionOutput> = recipe
        .sections
        .iter()
        .map(|section| SectionOutput {
            name: section.name.clone(),
            content: section
                .content
                .iter()
                .filter_map(|item| {
                    if let cooklang::Content::Step(step) = item {
                        Some(convert_step(&step))
                    } else {
                        None
                    }
                })
                .collect(),
        })
        .collect();

    let warning_strings: Vec<String> = report.warnings().map(|w| w.message.to_string()).collect();
    let diagnostics: Vec<DiagnosticOutput> = report
        .warnings()
        .map(|w| convert_diagnostic(w, input))
        .collect();

    RecipeOutput {
        metadata,
        ingredients,
        cookware,
        timers,
        sections,
        warnings: warning_strings,
        diagnostics,
    }
}

fn convert_quantity(q: &cooklang::Quantity) -> QuantityOutput {
    let value = match q.value() {
        cooklang::Value::Number(n) => Some(ValueOutput::Number(n.value())),
        cooklang::Value::Range { start, end } => Some(ValueOutput::Range {
            start: start.value(),
            end: end.value(),
        }),
        cooklang::Value::Text(t) => Some(ValueOutput::Text(t.clone())),
    };

    QuantityOutput {
        value,
        unit: q.unit().map(|s| s.to_string()),
        scalable: q.scalable(),
    }
}

fn convert_step(step: &cooklang::Step) -> StepOutput {
    let items: Vec<ItemOutput> = step
        .items
        .iter()
        .map(|item| match item {
            cooklang::Item::Text { value } => ItemOutput::Text {
                value: value.to_string(),
            },
            cooklang::Item::Ingredient { index } => ItemOutput::Ingredient { index: *index },
            cooklang::Item::Cookware { index } => ItemOutput::Cookware { index: *index },
            cooklang::Item::Timer { index } => ItemOutput::Timer { index: *index },
            cooklang::Item::InlineQuantity { index: _ } => ItemOutput::Text {
                value: String::new(),
            },
        })
        .collect();

    StepOutput { items }
}
