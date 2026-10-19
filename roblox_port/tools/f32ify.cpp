// f32ify: rewrites a Luau source so its arithmetic is done in f32, like the Rust it ports.
//
// The Rust (crates/sm_traversal) computes in f32; Luau numbers are f64. Rounding every operation's result to f32 makes
// the Luau compute exactly what the Rust computes (an f64 operation on f32 inputs, rounded to f32, is the correctly
// rounded f32 operation; sqrt likewise). Using Luau's own parser, it:
//   - wraps every arithmetic expression `a op b` (+ - * / // % ^) in __F(...);
//   - rewrites `x op= y` as `x = __F(x op (y))`;
//   - replaces each decimal number literal by its exact f32 value (hex literals, used for bit masks, are kept);
//   - wraps calls to sqrt / exp / sin / cos / acos / atan2 (bare or `math.`) in __F(...), as the Rust's f32 calls (or
//     its `(x as f64).f() as f32`) round them;
//   - leaves alone the body of any function whose name starts with `f64_` (where the Rust itself computes in f64, e.g.
//     the game clock; such functions round explicitly where the Rust does);
//   - defines __F at the top: a number through an f32 (a vector component is an f32); anything else (the V3 tables,
//     whose metamethods round their own components) as it is.
// Build: g++ -std=c++17 -O2 f32ify.cpp -I<luau>/Ast/include -I<luau>/Common/include <luau>/build/libLuau.Ast.a <luau>/build/libLuau.Common.a
// Use:   f32ify in.luau out.luau
#include "Luau/Ast.h"
#include "Luau/Parser.h"
#include <algorithm>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

using namespace Luau;

struct Edit
{
    size_t at;      // byte offset
    size_t end;     // for replacements: end of the replaced span (== at for insertions)
    int order;      // at the same offset: lower first
    std::string text;
};

static std::vector<size_t> lineStarts;
static std::string src;

static size_t off(const Position& p)
{
    return lineStarts.at(p.line) + p.column;
}

static bool isArith(AstExprBinary::Op op)
{
    switch (op)
    {
    case AstExprBinary::Add:
    case AstExprBinary::Sub:
    case AstExprBinary::Mul:
    case AstExprBinary::Div:
    case AstExprBinary::FloorDiv:
    case AstExprBinary::Mod:
    case AstExprBinary::Pow:
        return true;
    default:
        return false;
    }
}

static const char* opText(AstExprBinary::Op op)
{
    switch (op)
    {
    case AstExprBinary::Add: return "+";
    case AstExprBinary::Sub: return "-";
    case AstExprBinary::Mul: return "*";
    case AstExprBinary::Div: return "/";
    case AstExprBinary::FloorDiv: return "//";
    case AstExprBinary::Mod: return "%";
    case AstExprBinary::Pow: return "^";
    default: return "?";
    }
}

struct Rewriter : AstVisitor
{
    std::vector<Edit> edits;
    int depth = 0;

    void wrap(const Location& loc)
    {
        // outer expressions open first and close last; the depth orders nested ones that share an edge
        edits.push_back({off(loc.begin), off(loc.begin), 1000 + depth, "__F("});
        edits.push_back({off(loc.end), off(loc.end), 100000 - depth, ")"});
    }

    bool visit(AstExprFunction* f) override
    {
        std::string name = f->debugname.value ? f->debugname.value : "";
        if (name.rfind("f64_", 0) == 0)
            return false;
        return true;
    }
    bool visit(AstExprBinary* b) override
    {
        if (isArith(b->op))
        {
            wrap(b->location);
            depth++;
            b->left->visit(this);
            b->right->visit(this);
            depth--;
            return false;
        }
        return true;
    }
    bool visit(AstExprCall* c) override
    {
        std::string callee = src.substr(off(c->func->location.begin), off(c->func->location.end) - off(c->func->location.begin));
        static const char* names[] = {"sqrt", "exp", "sin", "cos", "acos", "atan2", "math.sqrt", "math.exp", "math.sin", "math.cos",
                                      "math.acos", "math.atan2", "acos_", "atan2_", "cos_", "sin_", "exp_"};
        bool rounded = false;
        for (const char* n : names)
            if (callee == n)
                rounded = true;
        if (rounded)
        {
            wrap(c->location);
            depth++;
            c->func->visit(this);
            for (AstExpr* a : c->args)
                a->visit(this);
            depth--;
            return false;
        }
        return true;
    }
    bool visit(AstExprConstantNumber* n) override
    {
        size_t a = off(n->location.begin), e = off(n->location.end);
        std::string text = src.substr(a, e - a);
        if (text.size() > 1 && text[0] == '0' && (text[1] == 'x' || text[1] == 'X' || text[1] == 'b' || text[1] == 'B'))
            return false;
        float f = (float)n->value;
        double d = (double)f;
        char buf[64];
        snprintf(buf, sizeof(buf), "%.17g", d);
        std::string out = buf;
        if (out == "inf" || out == "-inf")
            out = out[0] == '-' ? "-math.huge" : "math.huge";
        if (out != text)
            edits.push_back({a, e, 50000, out});
        return false;
    }
    bool visit(AstStatCompoundAssign* s) override
    {
        if (!isArith(s->op))
            return true;
        size_t varEnd = off(s->var->location.end), valBegin = off(s->value->location.begin);
        size_t varBegin = off(s->var->location.begin);
        std::string var = src.substr(varBegin, varEnd - varBegin);
        // the operator token sits between the target and the value
        edits.push_back({varEnd, valBegin, 50000, std::string(" = __F(") + var + " " + opText(s->op) + " ("});
        edits.push_back({off(s->value->location.end), off(s->value->location.end), 100000 + 1, "))"});
        depth++;
        s->value->visit(this);
        depth--;
        return false;
    }
};

int main(int argc, char** argv)
{
    if (argc != 3)
    {
        fprintf(stderr, "usage: f32ify in.luau out.luau\n");
        return 2;
    }
    std::ifstream in(argv[1], std::ios::binary);
    std::stringstream ss;
    ss << in.rdbuf();
    src = ss.str();
    lineStarts.push_back(0);
    for (size_t i = 0; i < src.size(); i++)
        if (src[i] == '\n')
            lineStarts.push_back(i + 1);
    for (unsigned char ch : src)
        if (ch >= 0x80)
        {
            fprintf(stderr, "%s: non-ASCII source (columns would be off)\n", argv[1]);
            return 1;
        }

    Allocator allocator;
    AstNameTable names(allocator);
    ParseOptions options;
    ParseResult result = Parser::parse(src.data(), src.size(), names, allocator, options);
    if (!result.errors.empty())
    {
        for (auto& e : result.errors)
            fprintf(stderr, "%s:%u: %s\n", argv[1], e.getLocation().begin.line + 1, e.getMessage().c_str());
        return 1;
    }
    Rewriter rw;
    result.root->visit(&rw);

    // apply: sort by offset, then order; replacements consume their span
    std::stable_sort(rw.edits.begin(), rw.edits.end(), [](const Edit& a, const Edit& b) {
        if (a.at != b.at)
            return a.at < b.at;
        return a.order < b.order;
    });
    std::string out;
    size_t cursor = 0;
    for (const Edit& e : rw.edits)
    {
        if (e.at < cursor)
        {
            fprintf(stderr, "%s: overlapping edit at %zu\n", argv[1], e.at);
            return 1;
        }
        out.append(src, cursor, e.at - cursor);
        out += e.text;
        cursor = e.end;
    }
    out.append(src, cursor, std::string::npos);

    // __F: the value through an f32 (vector components are f32); after any leading --! directives
    std::string header = "local __F = function(x: any): any if type(x) == \"number\" then return vector.create(x, 0, 0).x end return x end -- f32ify: f32 rounding (vector arithmetic rounds in its own metamethods)\n";
    size_t insertAt = 0;
    while (out.compare(insertAt, 3, "--!") == 0)
    {
        size_t nl = out.find('\n', insertAt);
        insertAt = nl == std::string::npos ? out.size() : nl + 1;
    }
    out.insert(insertAt, header);
    std::ofstream o(argv[2], std::ios::binary);
    o << out;
    return 0;
}
