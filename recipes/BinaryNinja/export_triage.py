"""Interactive Binary Ninja triage exporter.

Run from Binary Ninja with File -> Run Script...
"""

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


def collect_strings(binary_view):
    """Return Binary Ninja's detected strings, ordered by address."""
    lines = ["=== STRINGS ==="]
    count = 0

    for string in sorted(binary_view.strings, key=lambda item: item.start):
        detected = binary_view.get_string_at(string.start)
        if detected is None:
            continue

        lines.append(f"{string.start:#x}  {detected.value}")
        count += 1

    return "\n".join(lines), count


def collect_internal_functions(binary_view):
    """Return functions Binary Ninja identified inside the binary."""
    functions = sorted(binary_view.functions, key=lambda function: function.start)
    lines = ["=== INTERNAL FUNCTIONS ==="]
    lines.extend(
        f"{function.start:#x}  {function.name}"
        for function in functions
    )
    return "\n".join(lines), len(functions)


def collect_imported_functions(binary_view):
    """Return statically imported function symbols."""
    imports = binary_view.get_symbols_of_type(SymbolType.ImportedFunctionSymbol)
    imports = sorted(imports, key=lambda symbol: symbol.full_name.lower())
    lines = ["=== IMPORTED FUNCTIONS ==="]
    lines.extend(symbol.full_name for symbol in imports)
    return "\n".join(lines), len(imports)


def combine_sections(*sections):
    """Join report sections with one blank line between them."""
    return "\n\n".join(section for section in sections if section)


def copy_to_clipboard(text):
    """Copy text on Binary Ninja's main UI thread."""
    def copy():
        QApplication.clipboard().setText(text)

    mainthread.execute_on_main_thread_and_wait(copy)


def save_to_file(text):
    """Ask for a destination and save the report as UTF-8 text."""
    output_path = get_save_filename_input(
        "Save triage report",
        "*.txt",
    )

    if not output_path:
        print("Save cancelled.")
        return False

    with open(output_path, "w", encoding="utf-8") as output_file:
        output_file.write(text)

    print(f"Triage report saved to: {output_path}")
    return True


def choose_report(binary_view):
    """Ask which data to collect and return the formatted report."""
    choices = [
        "Strings",
        "Internal functions",
        "Imported functions",
        "All functions",
        "Full report",
    ]

    choice = get_choice_input(
        "What data should be collected?",
        "Loadbot Binary Ninja Recipe",
        choices,
    )

    if choice is None:
        return None, None

    if choice == 0:
        strings, count = collect_strings(binary_view)
        return strings, f"{count} strings"

    if choice == 1:
        internal, count = collect_internal_functions(binary_view)
        return internal, f"{count} internal functions"

    if choice == 2:
        imported, count = collect_imported_functions(binary_view)
        return imported, f"{count} imported functions"

    internal, internal_count = collect_internal_functions(binary_view)
    imported, imported_count = collect_imported_functions(binary_view)
    functions = combine_sections(internal, imported)
    function_summary = (
        f"{internal_count} internal functions and "
        f"{imported_count} imported functions"
    )

    if choice == 3:
        return functions, function_summary

    strings, string_count = collect_strings(binary_view)
    report = combine_sections(functions, strings)
    summary = f"{function_summary}, and {string_count} strings"
    return report, summary


def deliver_report(output, summary):
    """Ask how the report should be delivered and perform the selection."""
    choices = [
        "Print to console",
        "Copy to clipboard",
        "Save to file",
        "Print and copy",
        "Print, copy, and save",
    ]

    choice = get_choice_input(
        "How should the results be delivered?",
        "Loadbot Binary Ninja Recipe",
        choices,
    )

    if choice is None:
        print("Export cancelled.")
        return

    should_print = choice in (0, 3, 4)
    should_copy = choice in (1, 3, 4)
    should_save = choice in (2, 4)

    if should_print:
        print(output)

    if should_copy:
        copy_to_clipboard(output)
        print(f"Copied {summary} to clipboard.")

    if should_save:
        save_to_file(output)


def run(binary_view):
    """Run the interactive triage exporter for the active BinaryView."""
    output, summary = choose_report(binary_view)
    if output is None:
        print("Export cancelled.")
        return

    deliver_report(output, summary)


if __name__ == "__main__":
    run(bv)
