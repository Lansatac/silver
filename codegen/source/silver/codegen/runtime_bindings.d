module silver.codegen.runtime_bindings;

struct RuntimeFunction { string returnType; string[] params; string attributes; }
static immutable RuntimeFunction[string] runtime = [
    "silver_print_int":  RuntimeFunction("void", ["i64"]),
    "silver_print_uint": RuntimeFunction("void", ["i64"]),
    "silver_print_float": RuntimeFunction("void", ["double"]),
    "silver_print_bool": RuntimeFunction("void", ["i1 zeroext"]),
    "silver_print_string": RuntimeFunction("void", ["ptr", "i64"]),
    "silver_print_unit": RuntimeFunction("void", []),
    
    "silver_printl_int":  RuntimeFunction("void", ["i64"]),
    "silver_printl_uint": RuntimeFunction("void", ["i64"]),
    "silver_printl_float": RuntimeFunction("void", ["double"]),
    "silver_printl_bool": RuntimeFunction("void", ["i1 zeroext"]),
    "silver_printl_string": RuntimeFunction("void", ["ptr", "i64"]),
    "silver_printl_unit": RuntimeFunction("void", []),

    "silver_format_int":  RuntimeFunction("void", ["i64", "ptr", "ptr"]),
    "silver_format_uint": RuntimeFunction("void", ["i64", "ptr", "ptr"]),
    "silver_format_float": RuntimeFunction("void", ["double", "ptr", "ptr"]),
    "silver_format_bool": RuntimeFunction("void", ["i1 zeroext", "ptr", "ptr"]),

    "silver_read":        RuntimeFunction("i1", ["ptr", "ptr"]),
    "silver_alloc":       RuntimeFunction("ptr",  ["i64"]),
    "silver_array_append": RuntimeFunction("void", ["ptr", "i64", "ptr", "i64", "i64", "i1 zeroext", "ptr", "ptr"]),
    "silver_array_format": RuntimeFunction("void", ["ptr", "i64", "ptr", "ptr"]),

    "silver_string_compare": RuntimeFunction("i32", ["ptr", "i64", "ptr", "i64"]),
    "silver_panic":       RuntimeFunction("void", ["ptr"], "noreturn"),
    "silver_panic_message": RuntimeFunction("void", ["ptr", "i64"], "noreturn"),

    "silver_pow":         RuntimeFunction("double", ["double", "double"]),
    "silver_sqrt":        RuntimeFunction("double", ["double"]),
    "silver_exp":         RuntimeFunction("double", ["double"]),
    "silver_log":         RuntimeFunction("double", ["double"]),
    "silver_sin":         RuntimeFunction("double", ["double"]),
    "silver_cos":         RuntimeFunction("double", ["double"]),
    "silver_atan":        RuntimeFunction("double", ["double"]),
    "silver_nowNanos":    RuntimeFunction("i64", []),
];
