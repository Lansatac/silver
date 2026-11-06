module silver.codegen.runtime_bindings;

struct RuntimeFunction { string returnType; string[] params; string attributes; }
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
    "silver_alloc":       RuntimeFunction("ptr",  ["i64"]),

    "silver_pow_int":     RuntimeFunction("i64", ["i64", "i64"]),
    "silver_pow_float":   RuntimeFunction("double", ["double", "double"]),
    "silver_string_equals": RuntimeFunction("zeroext i1", ["ptr", "ptr"]),
    "silver_panic":       RuntimeFunction("void", ["ptr"], "noreturn"),

    "silver_toInt":       RuntimeFunction("i64", ["double"]),
    "silver_toFloat":     RuntimeFunction("double", ["i64"]),

    "silver_sqrt":        RuntimeFunction("double", ["double"]),
    "silver_exp":         RuntimeFunction("double", ["double"]),
    "silver_log":         RuntimeFunction("double", ["double"]),
    "silver_sin":         RuntimeFunction("double", ["double"]),
    "silver_cos":         RuntimeFunction("double", ["double"]),
    "silver_atan":        RuntimeFunction("double", ["double"]),
];
