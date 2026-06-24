-- Render fenced ```plantuml blocks to inline SVG for the markdown preview.
--
-- Pandoc passes every code block through this filter. For plantuml we shell
-- out to the local `plantuml' binary in pipe mode and splice the resulting
-- SVG straight into the HTML, so the xwidget-webkit preview shows the rendered
-- diagram (the same surface where mermaid renders client-side).
--
-- PlantUML needs Java, so there is no client-side renderer — this server-side
-- pass is how it reaches the preview. Any failure (binary missing, bad syntax)
-- returns nil, leaving the block as a normal code listing so the preview never
-- breaks.

function CodeBlock(el)
  if not el.classes:includes("plantuml") then
    return nil
  end
  local ok, out = pcall(pandoc.pipe, "plantuml", {"-tsvg", "-pipe"}, el.text)
  if not ok or not out or out == "" then
    return nil
  end
  -- Strip any leading processing instruction (`<?xml?>`, `<?plantuml?>`) and
  -- DOCTYPE so the <svg> embeds cleanly inline.
  out = out:gsub("<%?.-%?>", "")
  out = out:gsub("<!DOCTYPE.->", "")
  return pandoc.RawBlock("html", '<div class="plantuml">' .. out .. '</div>')
end
