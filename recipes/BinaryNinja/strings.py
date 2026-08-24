# Generate strings from binary and decide how to deal with data. 

from binaryninja import (
    get_choice_input,
    get_save_filename_input,
)

# Build strings section
string_lines = ["=== STRINGS ==="]

for string in sorted(bv.strings, key=lambda s: s.start):
    detected_string = bv.get_string_at(string.start)

    if detected_string is not None:
        string_lines.append(
            f"{string.start:#x}  {detected_string.value}"
        )

# Combine everything into one string
output = "\n".join(string_lines)

choices = [
    "Print to console",
    "Copy to clipboard",
    "Save to file",
    "Print and copy",
    "Print, copy, and save",
]

choice = get_choice_input(
    "What would you like to do with the string list?",
    "Export Strings",
    choices,
)

should_print = choice in (0, 3, 4)
should_copy = choice in (1, 3, 4)
should_save = choice in (2, 4)

if should_print:
    print(output)

if should_copy:
    try:
        from PySide6.QtWidgets import QApplication
    except ImportError:
        from PySide2.QtWidgets import QApplication

    QApplication.clipboard().setText(output)
    print(f"Copied {len(string_lines) - 1} strings to clipboard.")

if should_save:
    output_path = get_save_filename_input(
        "Save string list",
        "*.txt",
    )

    if output_path:
        with open(output_path, "w", encoding="utf-8") as output_file:
            output_file.write(output)

        print(f"String list saved to: {output_path}")

if choice is None:
    print("Export cancelled.")
