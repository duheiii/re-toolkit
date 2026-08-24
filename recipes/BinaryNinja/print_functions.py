# Prints internal and external fucntions with their address / location

from binaryninja import SymbolType

print("=== INTERNAL FUNCTIONS ===")
for function in sorted(bv.functions, key=lambda f: f.start):
    print(f"{function.start:#x}  {function.name}")

print("\n=== IMPORTED FUNCTIONS ===")
imports = bv.get_symbols_of_type(SymbolType.ImportedFunctionSymbol)

for symbol in sorted(imports, key=lambda s: s.full_name.lower()):
    print(symbol.full_name)
