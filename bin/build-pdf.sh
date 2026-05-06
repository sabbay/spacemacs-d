#!/usr/bin/env bash
# Build a pageless PDF from an org file via pandoc + typst.
#
# Produces a single-page PDF (height auto-sized to content, ~21 cm wide,
# 1.2 cm margins) with PlantUML source blocks hidden — only the rendered
# diagrams survive. Intended to be run right before `monday-docs-sync' so
# the synced attachment is fresh.
#
# Usage:
#   build-pdf.sh [path/to/FILE.org]
#   default: ./README.org
#
# Output: sibling file with .pdf extension (e.g. FILE.org → FILE.pdf).
#
# Dependencies: pandoc, typst. No LaTeX required.

set -euo pipefail

org_file="${1:-README.org}"

if [[ ! -f "$org_file" ]]; then
  echo "build-pdf: not found: $org_file" >&2
  exit 1
fi

for cmd in pandoc typst; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "build-pdf: required command not found: $cmd" >&2
    echo "  install with: brew install $cmd" >&2
    exit 1
  fi
done

org_abs="$(cd "$(dirname "$org_file")" && pwd)/$(basename "$org_file")"
work_dir="$(dirname "$org_abs")"
base="$(basename "${org_abs%.org}")"
typ_file="$work_dir/.${base}.typ"
pdf_file="$work_dir/${base}.pdf"

# Lua filter: drop every code block whose language is plantuml. The
# rendered PNG referenced in a sibling `#+RESULTS:' block stays intact.
filter_file="$(mktemp -t hide-plantuml.XXXXXX.lua)"
cat > "$filter_file" <<'LUA'
function CodeBlock(block)
  if block.classes and block.classes[1] == "plantuml" then
    return {}
  end
end
LUA

cleanup() {
  rm -f "$filter_file" "$typ_file"
}
trap cleanup EXIT

# Typst preamble — pageless layout + typography. Appended to pandoc's
# typst output so the document inherits these `set' rules.
#
# Pandoc's typst writer emits helper calls like `#horizontalrule` that
# only get defined when pandoc's standalone template is in play. We
# bypass the template (custom preamble), so we redefine the helpers
# pandoc assumes exist.
cat > "$typ_file" <<'TYPST'
#set page(width: 21cm, height: auto, margin: 1.2cm)
#set text(size: 10pt, font: "New Computer Modern")
#set par(justify: true, leading: 0.6em)
#show raw: set text(font: "DejaVu Sans Mono", size: 9pt)
#show heading.where(level: 1): set text(size: 16pt)
#show heading.where(level: 2): set text(size: 13pt)
#show heading.where(level: 3): set text(size: 11pt)
#show link: set text(fill: blue)

#let horizontalrule = line(start: (25%, 0%), end: (75%, 0%))
#let endnote(num, contents) = [
  #stack(dir: ltr, spacing: 3pt, super[#num], contents)
]

TYPST

# Pandoc's org reader swallows `#+RESULTS:' blocks whole, including the
# `[[file:foo.png]]' link that follows a `#+begin_src plantuml :file …'
# block — so diagrams vanish. Stripping just the keyword line leaves the
# link as a regular paragraph, which pandoc then emits as `#image(…)'.
sed 's/^#+RESULTS:[[:space:]]*$//' "$org_abs" \
  | pandoc -f org -t typst --lua-filter="$filter_file" >> "$typ_file"
typst compile "$typ_file" "$pdf_file"

echo "build-pdf: wrote $pdf_file"
