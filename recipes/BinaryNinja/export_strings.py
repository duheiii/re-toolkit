# Exports functions from binary allowing user to select where to store data

from binaryninja import (
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
        "Save string list",
        "*.txt",
    )

    if not output_path:
        print("Save cancelled.")
        return

    with open(output_path, "w", encoding="utf-8") as output_file:
        output_file.write(text)

    print(f"String list saved to: {output_path}")


# Collect detected strings
detected_strings = []

for string in sorted(bv.strings, key=lambda s: s.start):
    detected = bv.get_string_at(string.start)

    if detected is not None:
        detected_strings.append(
            (string.start, detected.value)
        )


# Build output
string_lines = ["=== STRINGS ==="]

for address, value in detected_strings:
    string_lines.append(f"{address:#x}  {value}")

output = "\n".join(string_lines)


# Ask how the output should be handled
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
            f"Copied {len(detected_strings)} strings "
            "to clipboard."
        )

    if should_save:
        save_to_file(output)
