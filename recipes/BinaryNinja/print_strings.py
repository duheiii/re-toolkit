for string in sorted(
    bv.strings,
    key=lambda s: bv.get_string_at(s.start).value.lower()
):
    print(bv.get_string_at(string.start).value)
