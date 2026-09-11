#!/usr/bin/env python3
"""
LaTeX Invisible Space Replacer & Compiler
- Replaces text-mode spaces with sequentially cycled invisible characters
- Skips math environments ($...$, \(...\), \[...\], $$...$$) and verbatim
- Injects required LaTeX packages/macros automatically
- Compiles the resulting PDF
"""

import os
import sys
import argparse
import subprocess

def process_latex(latex_content, char_string):
    """Replace text-mode spaces with sequential \z{char} commands."""
    math_mode = None  # None, 'inline', 'display'
    in_verbatim = False
    result = []
    char_idx = 0
    n = len(latex_content)
    i = 0

    while i < n:
        # Verbatim handling
        if not in_verbatim and latex_content[i:].startswith(r'\begin{verbatim}'):
            in_verbatim = True
            result.append(r'\begin{verbatim}')
            i += 15
            continue
        if in_verbatim and latex_content[i:].startswith(r'\end{verbatim}'):
            in_verbatim = False
            result.append(r'\end{verbatim}')
            i += 14
            continue

        # Math mode tracking
        if not in_verbatim:
            if math_mode is None:
                if latex_content[i:].startswith(r'\('):
                    math_mode = 'inline'
                    result.append(r'\(')
                    i += 2
                    continue
                if latex_content[i] == '$' and (i+1 >= n or latex_content[i+1] != '$'):
                    math_mode = 'inline'
                    result.append('$')
                    i += 1
                    continue
                if latex_content[i:].startswith(r'\['):
                    math_mode = 'display'
                    result.append(r'\[')
                    i += 2
                    continue
                if latex_content[i] == '$' and i+1 < n and latex_content[i+1] == '$':
                    math_mode = 'display'
                    result.append('$$')
                    i += 2
                    continue
            else:
                if math_mode == 'inline':
                    if latex_content[i:].startswith(r'\)'):
                        math_mode = None
                        result.append(r'\)')
                        i += 2
                        continue
                    if latex_content[i] == '$':
                        math_mode = None
                        result.append('$')
                        i += 1
                        continue
                elif math_mode == 'display':
                    if latex_content[i:].startswith(r'\]'):
                        math_mode = None
                        result.append(r'\]')
                        i += 2
                        continue
                    if latex_content[i] == '$' and i+1 < n and latex_content[i+1] == '$':
                        math_mode = None
                        result.append('$$')
                        i += 2
                        continue

        # Skip replacement inside math or verbatim
        if math_mode is not None or in_verbatim:
            result.append(latex_content[i])
            i += 1
            continue

        # Text mode: replace space
        if latex_content[i] == ' ':
            char = char_string[char_idx % len(char_string)]
            result.append(f'\\z{{{char}}}')
            char_idx += 1
        else:
            result.append(latex_content[i])
        i += 1

    return ''.join(result)

def ensure_preamble(content):
    """Inject xcolor and \z macro if missing."""
    pkg = r'\usepackage{xcolor}'
    macro = r'\newcommand{\z}[1]{\makebox[0pt]{\textcolor{white}{#1}}}'

    needs_pkg = pkg not in content and r'\usepackage{xcolor}' not in content
    needs_macro = r'\newcommand{\z}' not in content and r'\def\z' not in content

    if not needs_pkg and not needs_macro:
        return content

    lines = content.split('\n')
    insert_idx = -1
    for i, line in enumerate(lines):
        if line.strip().startswith(r'\documentclass'):
            insert_idx = i + 1
            break
    if insert_idx == -1:
        insert_idx = 0

    new_lines = lines[:insert_idx]
    if needs_pkg:
        new_lines.append(pkg)
    if needs_macro:
        new_lines.append(macro)
    new_lines.extend(lines[insert_idx:])
    return '\n'.join(new_lines)

def compile_pdf(tex_file, run_twice=True):
    """Compile LaTeX file using pdflatex."""
    cmd = ['pdflatex', '-interaction=nonstopmode', tex_file]
    for _ in range(2 if run_twice else 1):
        print(f"Running pdflatex (pass {_+1})...")
        result = subprocess.run(cmd, capture_output=True, text=True, cwd=os.path.dirname(os.path.abspath(tex_file)))
        if result.returncode != 0:
            print("⚠️ Compilation returned errors/warnings. Check the .log file.")
            # Print last few lines of stdout for quick debugging
            print(result.stdout.strip().split('\n')[-10:])
            return False
    return True

def main():
    parser = argparse.ArgumentParser(description="Insert invisible sequential characters into LaTeX and compile.")
    parser.add_argument("char_file", help="Text file containing the sequence of characters to insert")
    parser.add_argument("latex_file", help="Input LaTeX source file (.tex)")
    parser.add_argument("-o", "--output", default="output.tex", help="Output LaTeX file name (default: output.tex)")
    parser.add_argument("--no-compile", action="store_true", help="Skip PDF compilation after processing")
    args = parser.parse_args()

    # Load characters
    with open(args.char_file, 'r', encoding='utf-8') as f:
        chars = f.read().replace('\n', '').replace('\r', '').strip()
    if not chars:
        print("❌ Error: Character file is empty or contains only whitespace.")
        sys.exit(1)

    # Load LaTeX
    with open(args.latex_file, 'r', encoding='utf-8') as f:
        latex_content = f.read()

    # Process
    print("🔄 Processing LaTeX document...")
    processed = process_latex(latex_content, chars)
    processed = ensure_preamble(processed)

    # Save
    with open(args.output, 'w', encoding='utf-8') as f:
        f.write(processed)
    print(f"✅ Processed document saved to: {args.output}")

    # Compile
    if not args.no_compile:
        print("📦 Compiling PDF...")
        success = compile_pdf(args.output)
        if success:
            pdf_name = os.path.splitext(args.output)[0] + '.pdf'
            print(f"🎉 Success! PDF generated: {pdf_name}")
        else:
            print("❌ Compilation failed. Check the .log file for details.")

if __name__ == '__main__':
    main()
