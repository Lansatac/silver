module silver.ast.idcheck;

import std.format : format;
import std.sumtype : match;

import silver.ast.id;
import silver.ast.nodes;
import silver.ast.span;

/// Every node in `modules` that has no ID or shares one with another node of its
/// kind, described for a test failure. Empty when every node's ID is unique.
string[] idProblems(const(Module)[] modules...)
{
    auto check = new IdCheck;
    foreach (m; modules)
    {
        check.visit(m);
    }
    return check.problems;
}

private final class IdCheck
{
    string[] problems;
    /// Where each ID was first seen, keyed by node kind and ID.
    private string[string] seen;

    void see(N)(const Id!N id, Span span)
    {
        auto where = format("%s@%s", span.file, span.start);
        if (!id.isValid)
        {
            problems ~= format("%s at %s has no ID", N.stringof, where);
            return;
        }
        auto key = N.stringof ~ " " ~ id.toString;
        if (auto first = key in seen)
        {
            problems ~= format("%s at %s and %s share ID %s", N.stringof, *first, where, id);
            return;
        }
        seen[key] = where;
    }

    void visit(const Module m)
    {
        see(m.id, m.span);
        foreach (d; m.declarations)
        {
            d.kind.match!(k => visit(k, d.span));
        }
    }

    void visit(const ImportStmt i, Span span)
    {
        see(i.id, span);
    }

    void visit(const FunctionDecl f, Span span)
    {
        see(f.id, f.nameSpan);
        foreach (p; f.params)
        {
            see(p.id, p.nameSpan);
            visit(p.type);
        }
        visit(f.returnType);
        visit(f.body);
    }

    void visit(const Stmt s)
    {
        s.kind.match!(k => visit(k, s.span));
    }

    void visit(const VarDecl v, Span span)
    {
        see(v.id, v.nameSpan);
        visit(v.value);
        if (v.type !is null)
        {
            visit(*v.type);
        }
    }

    void visit(const AssignStmt a, Span span)
    {
        visit(a.target);
        visit(a.value);
    }

    void visit(const ExprStmt e, Span span)
    {
        visit(e.expr);
    }

    void visit(const ReturnStmt r, Span span)
    {
        visit(r.value);
    }

    void visit(const(Expr)* e)
    {
        if (e !is null)
        {
            visit(*e);
        }
    }

    void visit(const Expr e)
    {
        see(e.id, e.span);
        e.kind.match!(
            (const UnaryExpr u) => visit(u.operand),
            (const BinaryExpr b) { visit(b.left); visit(b.right); },
            (const CallExpr c) {
                visit(c.callee);
                foreach (arg; c.args)
                {
                    visit(arg);
                }
            },
            (const MemberAccess m) => visit(m.object),
            (const WhileExpr w) { visit(w.condition); visit(w.body); },
            (const IfExpr i) { visit(i.condition); visit(i.trueBody); visit(i.falseBody); },
            (const BlockExpr b) {
                foreach (s; b.statements)
                {
                    visit(s);
                }
                visit(b.value);
            },
            (_) {},
        );
    }

    void visit(const TypeExpr t)
    {
        see(t.id, t.span);
        t.kind.match!(
            (const OptionType o) => visit(*o.inner),
            (const NamedType n) {
                foreach (arg; n.args)
                {
                    visit(arg);
                }
            },
            (const FunctionType f) {
                foreach (p; f.params)
                {
                    visit(p);
                }
                visit(*f.returnType);
            },
            (const UnitType _) {},
        );
    }
}

version (unittest)
{
    private Module moduleOf(Expr[] exprs, NodeIds ids)
    {
        Stmt[] statements;
        foreach (e; exprs)
        {
            statements ~= Stmt(Span.init, StmtKind(ExprStmt(e)));
        }
        auto body = new Expr(ids.next!Expr, Span.init, ExprKind(BlockExpr(statements, null)));
        auto unit = TypeExpr(ids.next!TypeExpr, Span.init, TypeExprKind(UnitType()));
        auto main = FunctionDecl(ids.next!FunctionDecl, "main", Span.init, [], body, unit, false);
        return Module(ids.next!Module, "test", Span.init, [Decl(Span.init, DeclKind(main))]);
    }
}

@("idProblems accepts nodes with distinct IDs")
unittest
{
    auto ids = new NodeIds;
    auto a = Expr(ids.next!Expr, Span.init, ExprKind(IntLiteral(1)));
    auto b = Expr(ids.next!Expr, Span.init, ExprKind(IntLiteral(2)));
    assert(idProblems(moduleOf([a, b], ids)) == []);
}

@("idProblems reports a node without an ID")
unittest
{
    auto ids = new NodeIds;
    auto missing = Expr(Id!Expr.init, Span("a.ag", 7, 8), ExprKind(IntLiteral(1)));
    assert(idProblems(moduleOf([missing], ids)) == ["Expr at a.ag@7 has no ID"]);
}

@("idProblems reports two nodes of a kind sharing an ID")
unittest
{
    auto ids = new NodeIds;
    auto a = Expr(ids.next!Expr, Span("a.ag", 1, 2), ExprKind(IntLiteral(1)));
    auto copy = a;
    copy.span = Span("a.ag", 5, 6);
    assert(idProblems(moduleOf([a, copy], ids)) == ["Expr at a.ag@1 and a.ag@5 share ID 1"]);
}

@("idProblems checks IDs across modules")
unittest
{
    auto first = new NodeIds;
    auto second = new NodeIds;
    auto a = Expr(first.next!Expr, Span.init, ExprKind(IntLiteral(1)));
    auto b = Expr(second.next!Expr, Span.init, ExprKind(IntLiteral(2)));
    assert(idProblems(moduleOf([a], first), moduleOf([b], second)).length > 0);
}
