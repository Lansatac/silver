module silver.core.slots;

import std.sumtype : match;

import silver.core.nodes;

/// Gives every `Local` of each function its `slot`, and each function its `localCount`.
void numberLocals(ref Program program)
{
    bool[Local] numbered;
    foreach (ref func; program.functions)
    {
        size_t count;

        void number(Local local)
        {
            assert(local !in numbered, "`" ~ local.name ~ "` is a local of two functions, or bound twice");
            numbered[local] = true;
            local.slot = count++;
        }

        void visit(ref Expr e)
        {
            void all(Expr[] exprs)
            {
                foreach (ref expr; exprs) visit(expr);
            }

            e.kind.match!(
                (ref Call call) => all(call.args),
                (ref CallClosure call) {
                    visit(*call.callee);
                    all(call.args);
                },
                (ref MakeClosure closure) => all(closure.captures),
                (ref ForeignCall call) => all(call.args),
                (ref IntrinsicCall call) => all(call.args),
                (ref Prim prim) => all(prim.args),
                (ref Convert convert) => visit(*convert.value),
                (ref If if_) {
                    visit(*if_.condition);
                    visit(*if_.trueBody);
                    visit(*if_.falseBody);
                },
                (ref Block block) {
                    foreach (ref statement; block.statements)
                    {
                        statement.kind.match!(
                            (ref Let let) {
                                number(let.local);
                                visit(let.value);
                            },
                            (ref Assign assign) => visit(assign.value),
                            (ref AssignElement assign) {
                                visit(assign.index);
                                visit(assign.value);
                            },
                            (ref Eval eval) => visit(eval.expr),
                        );
                    }
                    if (block.result !is null) visit(*block.result);
                },
                (ref Loop loop) => visit(*loop.body),
                (ref Return return_) => visit(*return_.value),
                (ref Construct construct) => all(construct.fields),
                (ref Field field) => visit(*field.object),
                (ref Update update) {
                    visit(*update.object);
                    visit(*update.value);
                },
                (ref Inject inject) {
                    if (inject.payload !is null) visit(*inject.payload);
                },
                (ref IsMember test) => visit(*test.subject),
                (ref Payload payload) => visit(*payload.subject),
                (ref ArrayLit literal) => all(literal.elements),
                (ref Index index) {
                    visit(*index.array);
                    visit(*index.index);
                },
                (ref Slice slice) {
                    visit(*slice.array);
                    visit(*slice.start);
                    visit(*slice.end);
                },
                (ref Length length) => visit(*length.array),
                (ref Cell cell) => all(cell.args),
                (ref Capture capture) => visit(*capture.closure),
                (ref TestFailure failure) => visit(*failure.message),
                (ref UnitLit _) {},
                (ref BoolLit _) {},
                (ref IntLit _) {},
                (ref FloatLit _) {},
                (ref StringLit _) {},
                (ref LocalRef _) {},
                (ref Break _) {},
                (ref Continue _) {},
            );
        }

        foreach (param; func.params) number(param);
        foreach (capture; func.captures) number(capture);
        visit(func.body);
        func.localCount = count;
    }
}
