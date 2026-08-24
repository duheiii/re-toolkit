from binaryninja import SymbolType

for sym in sorted(
    bv.get_symbols_of_type(SymbolType.ImportedFunctionSymbol),
    key=lambda s: s.full_name.lower()
):
    print(sym.full_name)
