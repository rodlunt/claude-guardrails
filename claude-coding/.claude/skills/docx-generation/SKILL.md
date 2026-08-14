---
name: docx-generation
description: Use when creating or generating a Microsoft Word .docx file (reports, letters, formatted documents). Uses the JS docx package with explicit page size, real Paragraph breaks, proper table widths, heading styles, TOC, and footers.
---

# DOCX Generation

Create Word documents (.docx) using the `docx` package (JavaScript, NOT python-docx). Write a Node.js script and execute it to produce the file.

## Install

Add the package with pnpm (never npm, per the supply-chain ban): `pnpm add docx`. Run one-off scripts with `node <script>.js`.

## Rules (follow exactly)

- Set page size explicitly in DXA units. A4: 11906 x 16838. Never rely on defaults.
- Never use `\n` for line breaks. Use separate `Paragraph` elements.
- Never insert unicode bullet characters manually. Use `LevelFormat.BULLET` with a numbering config.
- For tables: set width with `WidthType.DXA` on the table, set `columnWidths` array, and set width on every cell. All three must be consistent. Never use `WidthType.PERCENTAGE`.
- Use `ShadingType.CLEAR` for table cell shading, never `ShadingType.SOLID`.
- For headings, override built-in styles using exact IDs: `"Heading1"`, `"Heading2"`, etc. Include `outlineLevel` (0 for H1, 1 for H2) on each heading style for TOC compatibility.
- For a table of contents, use `TableOfContents` from the docx package. Heading paragraphs must use `HeadingLevel` only, no custom styles on those paragraphs.
- Page numbers go in a `Footer` using `PageNumber`.
- Never use tables as horizontal dividers. Use a paragraph bottom border instead.
- After generating the file, confirm the output path.
