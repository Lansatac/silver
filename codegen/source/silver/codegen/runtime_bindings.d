module silver.codegen.runtime_bindings;

struct RuntimeFunction { string returnType; string[] params; }
static immutable RuntimeFunction[string] runtime = [
    "silver_print_int":  RuntimeFunction("void", ["i64"]),
    "silver_print_float": RuntimeFunction("void", ["double"]),
    "silver_print_bool": RuntimeFunction("void", ["i1 zeroext"]),
    "silver_print_string": RuntimeFunction("void", ["ptr"]),
    "silver_print_unit": RuntimeFunction("void", []),
    
    "silver_printl_int":  RuntimeFunction("void", ["i64"]),
    "silver_printl_float": RuntimeFunction("void", ["double"]),
    "silver_printl_bool": RuntimeFunction("void", ["i1 zeroext"]),
    "silver_printl_string": RuntimeFunction("void", ["ptr"]),
    "silver_printl_unit": RuntimeFunction("void", []),

    "silver_read":        RuntimeFunction("ptr",  []),
];
