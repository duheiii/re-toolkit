# Generate Functions and allow user to choose how to deal with data

from binaryninja import (
    SymbolType,
    get_choice_input,
    get_save_filename_input,
)

# Build internal-functions section
internal_lines = ["=== INTERNAL FUNCTIONS ==="]

for function in sorted(bv.functions, key=lambda f: f.start):
    internal_lines.append(f"{function.start:#x}  {function.name}")

# Build imported-functions section
imports = bv.get_symbols_of_type(SymbolType.ImportedFunctionSymbol)

import_lines = [
    "",
    "=== IMPORTED FUNCTIONS ===",
]

for symbol in sorted(imports, key=lambda s: s.full_name.lower()):
    import_lines.append(symbol.full_name)

# Combine everything into one string
output = "\n".join(internal_lines + import_lines)

choices = [
    "Print to console",
    "Copy to clipboard",
    "Save to file",
    "Print and copy",
    "Print, copy, and save",
]

choice = get_choice_input(
    "What would you like to do with the function list?",
    "Export Functions",
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
    print("Function list copied to clipboard.")

if should_save:
    output_path = get_save_filename_input(
        "Save function list",
        "*.txt",
    )

    if output_path:
        with open(output_path, "w", encoding="utf-8") as output_file:
            output_file.write(output)

        print(f"Function list saved to: {output_path}")

if choice is None:
    print("Export cancelled.")
