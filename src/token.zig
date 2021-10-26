const std = @import("std");
const mem = std.mem;

pub const Token = struct {
    const Self = @This();

    token_type: TokenType,
    lexeme: []const u8,
    // Literal is either a string or a number
    literal_string: ?[]const u8 = null,
    literal_number: ?f64 = null,
    line: usize,
    column: usize,
    offset: usize = 0,

    pub fn identifier(name: []const u8) Self {
        return .{
            .token_type = .Identifier,
            .lexeme = name,
            .line = 0,
            .column = 0,
        };
    }

    pub fn clone(self: Self) Self {
        return .{
            .token_type = self.token_type,
            .lexeme = self.lexeme,
            .literal_string = self.literal_string,
            .literal_number = self.literal_number,
            .line = self.line,
            .column = self.column,
        };
    }
};

// WARNING: don't reorder without reordering `rules` in compiler.zig
pub const TokenType = enum {
    Pipe, // |
    LeftBracket, // [
    RightBracket, // ]
    LeftParen, // (
    RightParen, // )
    LeftBrace, // {
    RightBrace, // }
    Dot, // .
    Comma, // ,
    Semicolon, // ;
    Greater, // >
    Less, // <
    Plus, // +
    Minus, // -
    Star, // *
    Slash, // /
    Percent, // %
    Question, // ?
    Bang, // !
    Colon, // :
    Equal, // =
    EqualEqual, // ==
    BangEqual, // !=
    GreaterEqual, // >=
    LessEqual, // <=
    QuestionQuestion, // ??
    PlusEqual, // +=
    MinusEqual, // -=
    StarEqual, // *=
    SlashEqual, // /=
    Increment, // ++
    Decrement, // --
    Arrow, // ->
    True, // true
    False, // false
    Null, // null
    Str, // str
    Num, // num
    Type, // type
    Bool, // bool
    Function, // Function
    ShiftRight, // >>
    ShiftLeft, // <<
    Xor, // xor
    Or, // or
    And, // and
    Return, // return
    If, // if
    Else, // else
    Do, // do
    Until, // until
    While, // while
    For, // for
    ForEach, // foreach
    Switch, // switch
    Break, // break
    Continue, // continue
    Default, // default
    In, // in
    Is, // is
    Number, // 123
    String, // "hello"
    Identifier, // anIdentifier
    Fun, // fun
    Object, // object
    Class, // class
    Enum, // enum
    Throw, // throw
    Try, // try
    Catch, // catch
    Test, // test
    Import, // import
    Export, // export
    Const, // const
    Static, // static
    Super, // super
    From, // from
    As, // as
    Extern, // extern
    Eof, // EOF
    Error, // Error
    Void, // void
    Yield, // yield
};

pub const Keywords = [_]TokenType{
    .True,
    .False,
    .Null,
    .Or,
    .And,
    .Return,
    .If,
    .Else,
    .While,
    .For,
    .ForEach,
    .Switch,
    .Break,
    .Continue,
    .Default,
    .Fun,
    .In,
    .Function,
    .Print,
    .Throw,
    .Try,
    .Catch,
    .Test,
    .Import,
    .Export,
    .Const,
    .Static,
    .Super,
    .From,
    .As,
    .Continue,
    .Extern,
    .Void,
};

// TODO: must be a way to write that more elegantly
pub fn isKeyword(literal: []const u8) ?TokenType {
    if (mem.eql(u8, literal, "void")) {
        return .Void;
    }

    if (mem.eql(u8, literal, "true")) {
        return .True;
    }

    if (mem.eql(u8, literal, "false")) {
        return .False;
    }

    if (mem.eql(u8, literal, "null")) {
        return .Null;
    }

    if (mem.eql(u8, literal, "or")) {
        return .Or;
    }

    if (mem.eql(u8, literal, "and")) {
        return .And;
    }

    if (mem.eql(u8, literal, "as")) {
        return .As;
    }

    if (mem.eql(u8, literal, "return")) {
        return .Return;
    }

    if (mem.eql(u8, literal, "if")) {
        return .If;
    }

    if (mem.eql(u8, literal, "else")) {
        return .Else;
    }

    if (mem.eql(u8, literal, "while")) {
        return .While;
    }

    if (mem.eql(u8, literal, "for")) {
        return .For;
    }

    if (mem.eql(u8, literal, "foreach")) {
        return .ForEach;
    }

    if (mem.eql(u8, literal, "switch")) {
        return .Switch;
    }

    if (mem.eql(u8, literal, "break")) {
        return .Break;
    }

    if (mem.eql(u8, literal, "continue")) {
        return .Continue;
    }

    if (mem.eql(u8, literal, "default")) {
        return .Default;
    }

    if (mem.eql(u8, literal, "const")) {
        return .Const;
    }

    if (mem.eql(u8, literal, "super")) {
        return .Super;
    }

    if (mem.eql(u8, literal, "fun")) {
        return .Fun;
    }

    if (mem.eql(u8, literal, "in")) {
        return .In;
    }

    if (mem.eql(u8, literal, "str")) {
        return .Str;
    }

    if (mem.eql(u8, literal, "num")) {
        return .Num;
    }

    if (mem.eql(u8, literal, "type")) {
        return .Type;
    }

    if (mem.eql(u8, literal, "bool")) {
        return .Bool;
    }

    if (mem.eql(u8, literal, "xor")) {
        return .Xor;
    }

    if (mem.eql(u8, literal, "do")) {
        return .Do;
    }

    if (mem.eql(u8, literal, "until")) {
        return .Until;
    }

    if (mem.eql(u8, literal, "is")) {
        return .Is;
    }

    if (mem.eql(u8, literal, "object")) {
        return .Object;
    }

    if (mem.eql(u8, literal, "static")) {
        return .Static;
    }

    if (mem.eql(u8, literal, "class")) {
        return .Class;
    }

    if (mem.eql(u8, literal, "enum")) {
        return .Enum;
    }

    if (mem.eql(u8, literal, "throw")) {
        return .Throw;
    }

    if (mem.eql(u8, literal, "try")) {
        return .Try;
    }

    if (mem.eql(u8, literal, "catch")) {
        return .Catch;
    }

    if (mem.eql(u8, literal, "test")) {
        return .Test;
    }

    if (mem.eql(u8, literal, "Function")) {
        return .Function;
    }

    if (mem.eql(u8, literal, "import")) {
        return .Import;
    }

    if (mem.eql(u8, literal, "export")) {
        return .Export;
    }

    if (mem.eql(u8, literal, "extern")) {
        return .Extern;
    }

    if (mem.eql(u8, literal, "from")) {
        return .From;
    }

    return null;
}
