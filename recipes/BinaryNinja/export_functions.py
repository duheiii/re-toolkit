# Exports functions from binary allowing user to select where to store data

from binaryninja import (
    SymbolType,
    get_choice_input,
    get_save_filename_input,
    mainthread,
)

try:
    from PySide6.QtWidgets import QApplication
except ImportError:
    from PySide2.QtWidgets import QApplication


def copy_to_clipboard(text):
    """Copy text using Binary Ninja's main UI thread."""

    def copy():
        QApplication.clipboard().setText(text)

    mainthread.execute_on_main_thread_and_wait(copy)


def save_to_file(text):
    """Prompt for a destination and save the output."""

    output_path = get_save_filename_input(
        "Save function list",
        "*.txt",
    )

    if not output_path:
        print("Save cancelled.")
        return

    with open(output_path, "w", encoding="utf-8") as output_file:
        output_file.write(text)

    print(f"Function list saved to: {output_path}")


# Build internal-functions section
internal_lines = ["=== INTERNAL FUNCTIONS ==="]

for function in sorted(bv.functions, key=lambda f: f.start):
    internal_lines.append(
        f"{function.start:#x}  {function.name}"
    )


# Build imported-functions section
imports = bv.get_symbols_of_type(
    SymbolType.ImportedFunctionSymbol
)

import_lines = [
    "",
    "=== IMPORTED FUNCTIONS ===",
]

for symbol in sorted(
    imports,
    key=lambda s: s.full_name.lower(),
):
    import_lines.append(symbol.full_name)


# Combine both sections
output = "\n".join(internal_lines + import_lines)


# Ask how the output should be handled
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


if choice is None:
    print("Export cancelled.")

else:
    should_print = choice in (0, 3, 4)
    should_copy = choice in (1, 3, 4)
    should_save = choice in (2, 4)

    if should_print:
        print(output)

    if should_copy:
        copy_to_clipboard(output)
        print(
            f"Copied {len(bv.functions)} internal functions "
            f"and {len(imports)} imports to clipboard."
        )

    if should_save:
        save_to_file(output)
