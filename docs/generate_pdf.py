#!/usr/bin/env python3
"""
Generate a single PDF containing the full cofounder plugin definition.

Features:
- Hierarchical table of contents with page numbers
- Page headers showing the current document path
- All agents, commands, skills, references, scripts, and examples
- Unicode support via TrueType fonts

Usage:
    ./generate_pdf.sh          # via wrapper (creates venv automatically)
    python3 generate_pdf.py    # if fpdf2 is already installed
"""

import json
import os
import platform
import re
import sys
from pathlib import Path

from fpdf import FPDF

PLUGIN_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_FILE = Path(__file__).resolve().parent / "cofounder-plugin.pdf"


def find_system_fonts():
    """Find suitable TrueType fonts on the system."""
    candidates_regular = []
    candidates_bold = []
    candidates_mono = []
    candidates_mono_bold = []

    system = platform.system()
    if system == "Darwin":
        font_dirs = [
            Path("/System/Library/Fonts"),
            Path("/Library/Fonts"),
            Path.home() / "Library/Fonts",
        ]
        # Prefer these fonts in order
        regular_names = ["Helvetica.ttc", "Arial.ttf", "Geneva.ttf"]
        bold_names = ["Helvetica Bold.ttc", "Arial Bold.ttf"]
        mono_names = ["Menlo.ttc", "Courier New.ttf", "SF-Mono-Regular.otf"]
        mono_bold_names = ["Menlo.ttc", "Courier New Bold.ttf", "SF-Mono-Bold.otf"]
    elif system == "Linux":
        font_dirs = [
            Path("/usr/share/fonts"),
            Path("/usr/local/share/fonts"),
            Path.home() / ".local/share/fonts",
        ]
        regular_names = ["DejaVuSans.ttf", "LiberationSans-Regular.ttf", "NotoSans-Regular.ttf"]
        bold_names = ["DejaVuSans-Bold.ttf", "LiberationSans-Bold.ttf", "NotoSans-Bold.ttf"]
        mono_names = ["DejaVuSansMono.ttf", "LiberationMono-Regular.ttf", "NotoSansMono-Regular.ttf"]
        mono_bold_names = ["DejaVuSansMono-Bold.ttf", "LiberationMono-Bold.ttf", "NotoSansMono-Bold.ttf"]
    else:
        font_dirs = [Path("C:/Windows/Fonts")]
        regular_names = ["arial.ttf", "calibri.ttf"]
        bold_names = ["arialbd.ttf", "calibrib.ttf"]
        mono_names = ["cour.ttf", "consola.ttf"]
        mono_bold_names = ["courbd.ttf", "consolab.ttf"]

    def find_font(dirs, names):
        for name in names:
            for d in dirs:
                p = d / name
                if p.exists():
                    return str(p)
                # Also search subdirectories
                for match in d.rglob(name):
                    return str(match)
        return None

    return {
        "regular": find_font(font_dirs, regular_names),
        "bold": find_font(font_dirs, bold_names),
        "mono": find_font(font_dirs, mono_names),
        "mono_bold": find_font(font_dirs, mono_bold_names),
    }


def discover_documents():
    """
    Walk the plugin tree and return an ordered list of
    (relative_path, toc_depth, display_title) tuples.
    """
    docs = []

    # 1. Plugin manifest
    docs.append((".claude-plugin/plugin.json", 0, "Plugin Manifest"))

    # 2. Root READMEs
    for name in sorted(PLUGIN_ROOT.glob("README*.md")):
        rel = name.relative_to(PLUGIN_ROOT)
        docs.append((str(rel), 0, str(rel)))

    # 3. Agents
    agents_dir = PLUGIN_ROOT / "agents"
    if agents_dir.is_dir():
        for f in sorted(agents_dir.rglob("*")):
            if f.is_file() and not f.name.startswith("."):
                rel = f.relative_to(PLUGIN_ROOT)
                docs.append((str(rel), 0, f"Agent: {f.stem}"))

    # 4. Commands
    commands_dir = PLUGIN_ROOT / "commands"
    if commands_dir.is_dir():
        for f in sorted(commands_dir.rglob("*")):
            if f.is_file() and not f.name.startswith("."):
                rel = f.relative_to(PLUGIN_ROOT)
                docs.append((str(rel), 0, f"Command: {f.stem}"))

    # 5. Skills (each skill is a chapter, sub-items are sections)
    skills_dir = PLUGIN_ROOT / "skills"
    if skills_dir.is_dir():
        for skill in sorted(skills_dir.iterdir()):
            if not skill.is_dir() or skill.name.startswith("."):
                continue

            skill_md = skill / "SKILL.md"
            if skill_md.exists():
                rel = skill_md.relative_to(PLUGIN_ROOT)
                docs.append((str(rel), 0, f"Skill: {skill.name}"))

            for subdir_name in ["references", "scripts", "examples"]:
                subdir = skill / subdir_name
                if not subdir.is_dir():
                    continue
                for f in sorted(subdir.rglob("*")):
                    if f.is_file() and not f.name.startswith("."):
                        rel = f.relative_to(PLUGIN_ROOT)
                        docs.append((str(rel), 1, f"{subdir_name}/{f.name}"))

            # .kamal subdirectory within examples
            kamal_dir = skill / "examples" / ".kamal"
            if kamal_dir.is_dir():
                for f in sorted(kamal_dir.iterdir()):
                    if f.is_file():
                        rel = f.relative_to(PLUGIN_ROOT)
                        docs.append((str(rel), 1, f"examples/.kamal/{f.name}"))

    return docs


def strip_markdown_links(text):
    """Convert [text](url) to just text."""
    return re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)


def strip_frontmatter(text):
    """Remove YAML frontmatter from markdown."""
    if text.startswith("---\n"):
        end = text.find("\n---\n", 4)
        if end != -1:
            return text[end + 5:]
        end = text.find("\n---", 4)
        if end != -1:
            return text[end + 4:]
    return text


class PluginPDF(FPDF):
    """Custom PDF with headers, footers, and TOC support."""

    def __init__(self, fonts):
        super().__init__(orientation="P", unit="mm", format="A4")
        self.current_doc_path = ""
        self._on_title_page = True
        self._on_toc_page = False
        self.set_auto_page_break(auto=True, margin=20)

        # Register Unicode fonts
        self._has_unicode = False
        if fonts["regular"] and fonts["mono"]:
            self._has_unicode = True
            self.add_font("Sans", "", fonts["regular"])
            self.add_font("Sans", "B", fonts["bold"] or fonts["regular"])
            self.add_font("Mono", "", fonts["mono"])
            self.add_font("Mono", "B", fonts["mono_bold"] or fonts["mono"])
            self._sans = "Sans"
            self._mono = "Mono"
        else:
            print("Warning: No Unicode TTF fonts found, falling back to latin-1", file=sys.stderr)
            self._sans = "Helvetica"
            self._mono = "Courier"

    def _sanitize(self, text):
        """Only sanitize if we don't have Unicode font support."""
        if self._has_unicode:
            return text
        return _sanitize_latin1(text)

    def header(self):
        if self._on_title_page or self._on_toc_page:
            return
        if not self.current_doc_path:
            return
        self.set_font(self._mono, size=7)
        self.set_text_color(100, 100, 100)
        self.cell(0, 6, self._sanitize(self.current_doc_path), align="L",
                  new_x="LMARGIN", new_y="NEXT")
        self.set_draw_color(180, 180, 180)
        self.line(10, self.get_y(), self.w - 10, self.get_y())
        self.ln(3)

    def footer(self):
        if self._on_title_page:
            return
        self.set_y(-15)
        self.set_font(self._sans, size=8)
        self.set_text_color(128, 128, 128)
        self.cell(0, 10, f"Page {self.page_no()}", align="C")

    def add_title_page(self, version):
        self._on_title_page = True
        self.add_page()
        self.ln(60)
        self.set_font(self._sans, "B", 28)
        self.set_text_color(0, 0, 0)
        self.cell(0, 15, "Cofounder Plugin", align="C", new_x="LMARGIN", new_y="NEXT")
        self.ln(5)
        self.set_font(self._sans, "", 14)
        self.set_text_color(80, 80, 80)
        self.cell(0, 10, "Complete Plugin Definition", align="C", new_x="LMARGIN", new_y="NEXT")
        self.ln(3)
        self.set_font(self._sans, "", 11)
        self.cell(0, 8, f"Version {version}", align="C", new_x="LMARGIN", new_y="NEXT")

    def render_toc(self, pdf, outline):
        """Callback for insert_toc_placeholder. Renders the TOC."""
        pdf.set_x(pdf.l_margin)
        pdf.set_font(self._sans, "B", 20)
        pdf.set_text_color(0, 0, 0)
        pdf.cell(0, 12, "Table of Contents", align="L", new_x="LMARGIN", new_y="NEXT")
        pdf.ln(6)

        for entry in outline:
            level = entry.level  # 0-based depth
            indent = level * 8
            page_no = entry.page_number

            if level == 0:
                pdf.set_font(self._sans, "B", 10)
                spacing = 6.5
            else:
                pdf.set_font(self._sans, "", 9)
                spacing = 5.5

            pdf.set_text_color(40, 40, 40)
            x = pdf.l_margin + indent
            pdf.set_x(x)
            title_w = pdf.w - pdf.l_margin - pdf.r_margin - indent - 15

            # Dot leader
            title_text = self._sanitize(entry.name)
            text_w = pdf.get_string_width(title_text)
            dot_w = pdf.get_string_width(".")
            dots_needed = max(0, int((title_w - text_w - 4) / dot_w))
            dots = " " + "." * dots_needed

            pdf.cell(title_w, spacing, title_text + dots)
            pdf.set_font(self._sans, "", 9)
            pdf.cell(15, spacing, str(page_no), align="R",
                     new_x="LMARGIN", new_y="NEXT")

    def start_document_section(self, rel_path, depth, title):
        """Start a new document section with proper section registration."""
        self.current_doc_path = rel_path
        self._on_title_page = False
        self._on_toc_page = False
        self.add_page()

        # Register in TOC via fpdf2's built-in section system
        self.start_section(self._sanitize(rel_path), level=depth)

        # Section title
        if depth == 0:
            self.set_font(self._sans, "B", 16)
        else:
            self.set_font(self._sans, "B", 13)
        self.set_text_color(0, 0, 0)
        self.multi_cell(0, 8, self._sanitize(title), new_x="LMARGIN", new_y="NEXT")
        self.ln(1)

        # Separator (path is already shown in the page header)
        self.set_draw_color(200, 200, 200)
        self.line(self.l_margin, self.get_y(), self.w - self.r_margin, self.get_y())
        self.ln(4)

    def render_document(self, rel_path, content):
        """Render a document's content onto pages."""
        self.set_text_color(0, 0, 0)

        if rel_path.endswith(".md"):
            content = strip_frontmatter(content)
            self._render_markdown(content)
        else:
            self._render_code_block(content)

    def _render_code_block(self, text):
        """Render text as monospace code."""
        self.set_font(self._mono, size=7.5)
        self.set_fill_color(245, 245, 245)
        usable_w = self.w - self.l_margin - self.r_margin

        for line in text.split("\n"):
            line = self._sanitize(line)
            self.multi_cell(usable_w, 3.8, "  " + line,
                            new_x="LMARGIN", new_y="NEXT", fill=True)

    def _render_markdown(self, text):
        """Render markdown with basic formatting."""
        in_code_block = False

        for raw_line in text.split("\n"):
            line = self._sanitize(raw_line)

            # Fenced code blocks
            if line.strip().startswith("```"):
                in_code_block = not in_code_block
                if in_code_block:
                    self.ln(1)
                else:
                    self.ln(1)
                continue

            if in_code_block:
                self.set_font(self._mono, size=7)
                self.set_fill_color(240, 240, 240)
                usable_w = self.w - self.l_margin - self.r_margin
                self.multi_cell(usable_w, 3.5, "  " + line,
                                new_x="LMARGIN", new_y="NEXT", fill=True)
                continue

            # Headings
            heading_match = re.match(r"^(#{1,6})\s+(.*)", line)
            if heading_match:
                level = len(heading_match.group(1))
                heading_text = strip_markdown_links(heading_match.group(2))
                sizes = {1: 14, 2: 12, 3: 11, 4: 10, 5: 9.5, 6: 9}
                self._md_heading(heading_text, sizes.get(level, 9))
                continue

            if line.strip() == "":
                self.ln(2.5)
                continue

            if re.match(r"^-{3,}\s*$", line):
                y = self.get_y()
                self.set_draw_color(200, 200, 200)
                self.line(self.l_margin, y, self.w - self.r_margin, y)
                self.ln(3)
                continue

            # Strip markdown links for display
            line = strip_markdown_links(line)

            # Regular paragraph text — use multi_cell for wrapping
            self._render_rich_line(line)

    def _md_heading(self, text, size):
        self.ln(2)
        self.set_font(self._sans, "B", size)
        self.set_text_color(0, 0, 0)
        usable_w = self.w - self.l_margin - self.r_margin
        self.multi_cell(usable_w, size * 0.5, text, new_x="LMARGIN", new_y="NEXT")
        self.ln(1.5)

    def _render_rich_line(self, line):
        """Render a line with inline `code`, **bold**, wrapping properly."""
        line_height = 4.5
        usable_w = self.w - self.l_margin - self.r_margin

        # Split by inline code backticks
        parts = re.split(r"(`[^`]+`)", line)

        # Check if total content is simple enough to use multi_cell
        has_formatting = any(
            (p.startswith("`") and p.endswith("`")) or "**" in p
            for p in parts if p
        )

        if not has_formatting:
            # Simple text — just use multi_cell for proper wrapping
            self.set_font(self._sans, "", 9)
            self.set_text_color(0, 0, 0)
            self.multi_cell(usable_w, line_height, line,
                            new_x="LMARGIN", new_y="NEXT")
            return

        # Complex line with formatting — render piece by piece
        for part in parts:
            if not part:
                continue

            if part.startswith("`") and part.endswith("`"):
                code_text = part[1:-1]
                self.set_font(self._mono, size=8)
                self.set_fill_color(235, 235, 235)
                w = self.get_string_width(code_text) + 2
                if self.get_x() + w > self.w - self.r_margin:
                    self.ln(line_height)
                self.cell(w, line_height, code_text, fill=True)
            else:
                # Handle bold segments
                bold_parts = re.split(r"(\*\*[^*]+\*\*)", part)
                for bp in bold_parts:
                    if not bp:
                        continue
                    if bp.startswith("**") and bp.endswith("**"):
                        self.set_font(self._sans, "B", 9)
                        text = bp[2:-2]
                    else:
                        self.set_font(self._sans, "", 9)
                        text = bp

                    self.set_text_color(0, 0, 0)
                    # Word-wrap manually for long segments
                    words = text.split(" ")
                    for i, word in enumerate(words):
                        if i > 0:
                            space_w = self.get_string_width(" ")
                            if self.get_x() + space_w <= self.w - self.r_margin:
                                self.cell(space_w, line_height, " ")
                        w = self.get_string_width(word)
                        if w > 0 and self.get_x() + w > self.w - self.r_margin:
                            self.ln(line_height)
                        if word:
                            self.cell(w, line_height, word)

        self.ln(line_height)


def _sanitize_latin1(text):
    """Replace characters that latin-1 can't encode."""
    replacements = {
        "\u2014": "--", "\u2013": "-", "\u2018": "'", "\u2019": "'",
        "\u201c": '"', "\u201d": '"', "\u2026": "...", "\u2022": "*",
        "\u00a0": " ", "\u2192": "->", "\u2190": "<-", "\u2794": "->",
        "\u2713": "[x]", "\u2717": "[ ]", "\u2605": "*",
    }
    for char, replacement in replacements.items():
        text = text.replace(char, replacement)

    # Strip emoji (multi-byte unicode blocks)
    text = re.sub(
        r"[\U0001F300-\U0001F9FF\U0001FA00-\U0001FA6F\U0001FA70-\U0001FAFF"
        r"\U00002702-\U000027B0\U0000FE00-\U0000FE0F\U0000200D]+",
        "", text
    )

    result = []
    for ch in text:
        try:
            ch.encode("latin-1")
            result.append(ch)
        except UnicodeEncodeError:
            result.append("")  # silently drop instead of ???
    return "".join(result)


def get_version():
    manifest = PLUGIN_ROOT / ".claude-plugin" / "plugin.json"
    with open(manifest) as f:
        data = json.load(f)
    return data.get("version", "unknown")


def main():
    documents = discover_documents()
    version = get_version()

    fonts = find_system_fonts()
    print(f"Fonts: regular={fonts['regular']}, mono={fonts['mono']}")

    pdf = PluginPDF(fonts)
    pdf.set_title(f"Cofounder Plugin v{version}")
    pdf.set_author("Cofounder Plugin")

    # Title page
    pdf.add_title_page(version)

    # TOC placeholder — fpdf2 will fill this in automatically at output time
    pdf._on_title_page = False
    pdf._on_toc_page = True
    pdf.add_page()
    # Estimate TOC pages: ~45 entries at ~6mm each = ~270mm, A4 usable ~257mm = ~2 pages
    toc_pages = max(1, (len(documents) * 7) // 257 + 1)
    pdf.insert_toc_placeholder(pdf.render_toc, pages=toc_pages)
    pdf._on_toc_page = False

    # Render all documents
    for rel_path, depth, title in documents:
        full_path = PLUGIN_ROOT / rel_path
        if not full_path.exists():
            continue

        pdf.start_document_section(rel_path, depth, title)

        try:
            content = full_path.read_text(encoding="utf-8")
        except Exception:
            content = full_path.read_bytes().decode("utf-8", errors="replace")

        pdf.render_document(rel_path, content)

    pdf.output(str(OUTPUT_FILE))
    print(f"PDF generated: {OUTPUT_FILE}")
    print(f"Total pages: {pdf.pages_count}")
    print(f"Documents included: {len(documents)}")


if __name__ == "__main__":
    main()
