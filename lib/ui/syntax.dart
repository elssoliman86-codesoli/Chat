import 'package:flutter/painting.dart';

/// What a run of code is, for coloring. Every character of the input belongs to exactly one token, in
/// order, so joining the tokens' text always gives back the original code unchanged.
enum TokenKind { plain, keyword, constant, type, function, string, number, comment, property, decorator, tag, attribute, variable }

class CodeToken {
  const CodeToken(this.text, this.kind);
  final String text;
  final TokenKind kind;
}

/// Colors for [TokenKind]s — a dark, VS Code–style palette (what most terminals and editors people
/// compare this to use): keywords purple, functions yellow, strings orange, numbers light green,
/// comments green and italic, types teal, constants/tags blue, properties/variables light blue.
class CodeTheme {
  const CodeTheme();
  static const CodeTheme dark = CodeTheme();

  Color get background => const Color(0xFF16181D);
  Color get header => const Color(0xFF1F2329);
  Color get gutter => const Color(0xFF5C6370);
  Color get headerText => const Color(0xFF9AA3B2);

  Color colorOf(TokenKind k) => switch (k) {
        TokenKind.plain => const Color(0xFFD4D4D4),
        TokenKind.keyword => const Color(0xFFC586C0),
        TokenKind.constant => const Color(0xFF569CD6),
        TokenKind.type => const Color(0xFF4EC9B0),
        TokenKind.function => const Color(0xFFDCDCAA),
        TokenKind.string => const Color(0xFFCE9178),
        TokenKind.number => const Color(0xFFB5CEA8),
        TokenKind.comment => const Color(0xFF6A9955),
        TokenKind.property => const Color(0xFF9CDCFE),
        TokenKind.decorator => const Color(0xFFDCDCAA),
        TokenKind.tag => const Color(0xFF569CD6),
        TokenKind.attribute => const Color(0xFF9CDCFE),
        TokenKind.variable => const Color(0xFF9CDCFE),
      };

  TextStyle styleOf(TokenKind k, TextStyle base) => base.copyWith(
        color: colorOf(k),
        fontStyle: k == TokenKind.comment ? FontStyle.italic : FontStyle.normal,
      );
}

/// The bundled monospace font (DejaVu Sans Mono, assets/fonts) with the system monospace behind it for
/// glyphs it lacks (Arabic text inside a string, say).
const String kCodeFont = 'DejaVuSansMono';
const List<String> kCodeFontFallback = <String>['monospace'];

TextStyle codeTextStyle({double size = 13, double height = 1.45}) =>
    TextStyle(fontFamily: kCodeFont, fontFamilyFallback: kCodeFontFallback, fontSize: size, height: height, color: CodeTheme.dark.colorOf(TokenKind.plain));

/// A fixed line height for both the line-number gutter and the code beside it, so every number sits
/// exactly beside its line even when a line contains taller glyphs (Arabic, emoji).
StrutStyle codeStrut({double size = 13, double height = 1.45}) =>
    StrutStyle(fontFamily: kCodeFont, fontFamilyFallback: kCodeFontFallback, fontSize: size, height: height, forceStrutHeight: true);

/// The highlighting language for a file name or path by its extension ('' when there is none we color).
String languageForPath(String path) {
  final name = path.split('/').last.toLowerCase();
  if (name == 'dockerfile') return 'bash';
  final dot = name.lastIndexOf('.');
  if (dot < 0) return '';
  final ext = name.substring(dot + 1);
  const aliases = <String, String>{'htm': 'html', 'gradle': 'java', 'kts': 'kotlin', 'vue': 'html', 'env': 'toml', 'conf': 'toml', 'cfg': 'toml'};
  final lang = aliases[ext] ?? ext;
  return canHighlight(lang) ? lang : '';
}

/// Beyond this many characters a block is shown uncolored — a very long paste would otherwise mean
/// thousands of spans re-laid-out on every streamed update.
const int kMaxHighlightChars = 60000;

class _Lang {
  const _Lang({
    this.keywords = const <String>{},
    this.constants = const <String>{},
    this.types = const <String>{},
    this.lineComments = const <String>[],
    this.blockComment,
    this.quotes = const <String>['"', "'"],
    this.tripleQuotes = false,
    this.caseInsensitive = false,
    this.dollarVars = false,
    this.decorators = false,
    this.cssProps = false,
    this.keyedLines = false,
    this.jsonLike = false,
  });

  final Set<String> keywords;
  final Set<String> constants;
  final Set<String> types;
  final List<String> lineComments;
  final (String, String)? blockComment;
  final List<String> quotes;
  final bool tripleQuotes;
  final bool caseInsensitive;
  final bool dollarVars;
  final bool decorators;
  final bool cssProps;
  final bool keyedLines;
  final bool jsonLike;
}

Set<String> _w(String s) => s.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toSet();

final Map<String, _Lang> _langs = _buildLangs();

Map<String, _Lang> _buildLangs() {
  final python = _Lang(
    keywords: _w('and as assert async await break class continue def del elif else except finally for from global if import in is lambda '
        'nonlocal not or pass raise return try while with yield match case'),
    constants: _w('True False None self cls'),
    types: _w('int str float bool list dict set tuple bytes object type Exception'),
    lineComments: const ['#'],
    tripleQuotes: true,
    decorators: true,
  );
  final js = _Lang(
    keywords: _w('async await break case catch class const continue debugger default delete do else export extends finally for from function '
        'if import in instanceof let new of return static super switch this throw try typeof var void while with yield get set as'),
    constants: _w('true false null undefined NaN Infinity'),
    types: _w('Array Object String Number Boolean Promise Map Set Date Error JSON Math Symbol RegExp console document window'),
    lineComments: const ['//'],
    blockComment: ('/*', '*/'),
    quotes: const ['"', "'", '`'],
  );
  final ts = _Lang(
    keywords: {
      ..._w('async await break case catch class const continue debugger default delete do else export extends finally for from function '
          'if import in instanceof let new of return static super switch this throw try typeof var void while with yield get set as '
          'interface type enum implements namespace declare readonly abstract public private protected keyof is infer satisfies'),
    },
    constants: _w('true false null undefined NaN Infinity'),
    types: _w('string number boolean any unknown never void object Array Record Partial Promise Map Set Date Error'),
    lineComments: const ['//'],
    blockComment: ('/*', '*/'),
    quotes: const ['"', "'", '`'],
    decorators: true,
  );
  final dart = _Lang(
    keywords: _w('abstract as assert async await break case catch class const continue covariant default deferred do dynamic else enum export '
        'extends extension external factory final finally for Function get hide if implements import in interface is late library mixin new on '
        'operator part required rethrow return sealed set show static super switch sync this throw try typedef var void while with yield'),
    constants: _w('true false null'),
    types: _w('int double num String bool List Map Set Future Stream Object Iterable Duration DateTime Widget BuildContext State Key'),
    lineComments: const ['//'],
    blockComment: ('/*', '*/'),
    tripleQuotes: true,
    decorators: true,
  );
  final java = _Lang(
    keywords: _w('abstract assert break case catch class const continue default do else enum extends final finally for goto if implements import '
        'instanceof interface native new package private protected public return static strictfp super switch synchronized this throw throws '
        'transient try var void volatile while record sealed permits fun val when object companion override open data lateinit suspend in is as'),
    constants: _w('true false null'),
    types: _w('int long short byte char float double boolean String Integer Long Double Boolean Object List Map Set Optional Unit Any'),
    lineComments: const ['//'],
    blockComment: ('/*', '*/'),
    tripleQuotes: true,
    decorators: true,
  );
  final cLike = _Lang(
    keywords: _w('auto break case catch class const constexpr continue default delete do else enum explicit extern for friend goto if inline '
        'namespace new noexcept nullptr operator private protected public register return sizeof static struct switch template this throw try '
        'typedef typename union using virtual volatile while override final using foreach in out ref params abstract sealed readonly event '
        'delegate async await partial where yield get set'),
    constants: _w('true false NULL nullptr null TRUE FALSE'),
    types: _w('int long short char float double bool void unsigned signed size_t uint8_t uint16_t uint32_t uint64_t int8_t int16_t int32_t '
        'int64_t string String var object decimal byte sbyte'),
    lineComments: const ['//'],
    blockComment: ('/*', '*/'),
  );
  final go = _Lang(
    keywords: _w('break case chan const continue default defer else fallthrough for func go goto if import interface map package range return '
        'select struct switch type var'),
    constants: _w('true false nil iota'),
    types: _w('int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 float32 float64 string bool byte rune error any'),
    lineComments: const ['//'],
    blockComment: ('/*', '*/'),
    quotes: const ['"', "'", '`'],
  );
  final rust = _Lang(
    keywords: _w('as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return '
        'self Self static struct super trait type unsafe use where while'),
    constants: _w('true false None Some Ok Err'),
    types: _w('i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str String Vec Option Result Box Rc Arc'),
    lineComments: const ['//'],
    blockComment: ('/*', '*/'),
  );
  final php = _Lang(
    keywords: _w('abstract and as break case catch class clone const continue declare default do echo else elseif empty enddeclare endfor '
        'endforeach endif endswitch endwhile extends final finally fn for foreach function global if implements include include_once instanceof '
        'interface isset list namespace new or print private protected public require require_once return static switch throw trait try unset '
        'use var while xor yield'),
    constants: _w('true false null TRUE FALSE NULL'),
    types: _w('int float string bool array object callable iterable void mixed'),
    lineComments: const ['//', '#'],
    blockComment: ('/*', '*/'),
    dollarVars: true,
  );
  final ruby = _Lang(
    keywords: _w('alias and begin break case class def defined do else elsif end ensure for if in module next not or redo rescue retry return '
        'self super then undef unless until when while yield require require_relative attr_accessor attr_reader attr_writer'),
    constants: _w('true false nil'),
    lineComments: const ['#'],
  );
  final bash = _Lang(
    keywords: _w('if then else elif fi for while until do done case esac in function select time return exit break continue local export '
        'readonly declare unset shift source alias echo cd ls cat grep sed awk pkg apt apt-get pip pip3 python python3 git ssh scp curl wget '
        'sudo chmod chown mkdir rm cp mv touch tar unzip kill ps'),
    constants: _w('true false'),
    lineComments: const ['#'],
    quotes: const ['"', "'", '`'],
    dollarVars: true,
  );
  final sql = _Lang(
    keywords: _w('select from where and or not insert into values update set delete create table alter drop index view join inner outer left '
        'right full cross on as group by order having limit offset union all distinct case when then else end is null in like between exists '
        'primary key foreign references default unique check constraint begin commit rollback transaction with asc desc count sum avg min max'),
    constants: _w('true false null'),
    types: _w('int integer bigint smallint varchar char text boolean bool date datetime timestamp float double decimal numeric serial'),
    lineComments: const ['--'],
    blockComment: ('/*', '*/'),
    caseInsensitive: true,
  );
  final css = _Lang(
    keywords: _w('important'),
    constants: _w('none auto inherit initial unset block inline flex grid absolute relative fixed sticky solid dashed transparent'),
    lineComments: const [],
    blockComment: ('/*', '*/'),
    cssProps: true,
  );
  final yaml = _Lang(constants: _w('true false null yes no on off'), lineComments: const ['#'], keyedLines: true);
  final toml = _Lang(constants: _w('true false'), lineComments: const ['#'], keyedLines: true);
  final json = _Lang(constants: _w('true false null'), jsonLike: true);
  final html = _Lang(blockComment: ('<!--', '-->'));

  return <String, _Lang>{
    'python': python, 'py': python, 'python3': python,
    'javascript': js, 'js': js, 'jsx': js, 'mjs': js, 'cjs': js, 'node': js,
    'typescript': ts, 'ts': ts, 'tsx': ts,
    'dart': dart,
    'java': java, 'kotlin': java, 'kt': java, 'scala': java, 'groovy': java, 'swift': java,
    'c': cLike, 'cpp': cLike, 'c++': cLike, 'cc': cLike, 'h': cLike, 'hpp': cLike, 'cs': cLike, 'csharp': cLike, 'objc': cLike,
    'go': go, 'golang': go,
    'rust': rust, 'rs': rust,
    'php': php,
    'ruby': ruby, 'rb': ruby,
    'bash': bash, 'sh': bash, 'shell': bash, 'zsh': bash, 'termux': bash, 'console': bash, 'powershell': bash, 'ps1': bash,
    'sql': sql, 'mysql': sql, 'postgres': sql, 'postgresql': sql, 'sqlite': sql,
    'css': css, 'scss': css, 'less': css,
    'yaml': yaml, 'yml': yaml,
    'toml': toml, 'ini': toml,
    'json': json, 'jsonc': json,
    'html': html, 'xml': html, 'svg': html, 'xhtml': html, 'vue': html,
  };
}

/// Whether [language] has colors; unknown languages (and plain text) are shown in one plain color.
bool canHighlight(String language) => _langs.containsKey(language.trim().toLowerCase());

bool _isIdentStart(int c) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 || c > 127;
bool _isIdentPart(int c) => _isIdentStart(c) || (c >= 48 && c <= 57);
bool _isDigit(int c) => c >= 48 && c <= 57;

/// Splits [code] into colored tokens for [language]. Lossless: the tokens' text joined is exactly [code].
List<CodeToken> tokenize(String code, String language) {
  final lang = _langs[language.trim().toLowerCase()];
  if (lang == null || code.isEmpty || code.length > kMaxHighlightChars) {
    return code.isEmpty ? const <CodeToken>[] : <CodeToken>[CodeToken(code, TokenKind.plain)];
  }
  final key = language.trim().toLowerCase();
  if (_langs[key] == _langs['html']) return _tokenizeMarkup(code);

  final out = <CodeToken>[];
  final n = code.length;
  var i = 0;
  var plainStart = 0;

  void flushPlain(int end) {
    if (end > plainStart) out.add(CodeToken(code.substring(plainStart, end), TokenKind.plain));
  }

  void emit(int start, int end, TokenKind kind) {
    flushPlain(start);
    out.add(CodeToken(code.substring(start, end), kind));
    plainStart = end;
    i = end;
  }

  // Start of the current line, for YAML/TOML "key:" detection.
  bool atLineStartKey(int from) {
    var j = from - 1;
    while (j >= 0 && code[j] != '\n') {
      final ch = code[j];
      if (ch != ' ' && ch != '\t' && ch != '-') return false;
      j--;
    }
    return true;
  }

  while (i < n) {
    final c = code.codeUnitAt(i);

    // Block comment
    final bc = lang.blockComment;
    if (bc != null && code.startsWith(bc.$1, i)) {
      final close = code.indexOf(bc.$2, i + bc.$1.length);
      emit(i, close == -1 ? n : close + bc.$2.length, TokenKind.comment);
      continue;
    }
    // Line comment
    var isLineComment = false;
    for (final lc in lang.lineComments) {
      if (code.startsWith(lc, i)) {
        // In shell, "#" only starts a comment at a word boundary, not inside $# or ${#x}.
        if (lc == '#' && lang.dollarVars && i > 0 && code[i - 1] == r'$') break;
        isLineComment = true;
        break;
      }
    }
    if (isLineComment) {
      final eol = code.indexOf('\n', i);
      emit(i, eol == -1 ? n : eol, TokenKind.comment);
      continue;
    }
    // Strings
    if (lang.quotes.contains(code[i])) {
      final q = code[i];
      final triple = lang.tripleQuotes && code.startsWith(q * 3, i);
      var j = i + (triple ? 3 : 1);
      final multiline = triple || q == '`';
      while (j < n) {
        final ch = code[j];
        if (ch == '\\' && !(lang.quotes.contains("'") && q == "'" && key == 'bash')) {
          j += 2;
          continue;
        }
        if (triple) {
          if (code.startsWith(q * 3, j)) {
            j += 3;
            break;
          }
        } else if (ch == q) {
          j++;
          break;
        }
        if (ch == '\n' && !multiline) break;
        j++;
      }
      if (j > n) j = n;
      emit(i, j, TokenKind.string);
      continue;
    }
    // Shell/PHP variables
    if (lang.dollarVars && c == 36 /* $ */ && i + 1 < n) {
      var j = i + 1;
      if (code[j] == '{') {
        final close = code.indexOf('}', j);
        j = close == -1 ? n : close + 1;
      } else {
        while (j < n && (_isIdentPart(code.codeUnitAt(j)) || code[j] == '?' || code[j] == '@' || code[j] == '*' || code[j] == '#' && j == i + 1)) {
          j++;
        }
      }
      if (j > i + 1) {
        emit(i, j, TokenKind.variable);
        continue;
      }
    }
    // Decorators / annotations
    if (lang.decorators && c == 64 /* @ */ && i + 1 < n && _isIdentStart(code.codeUnitAt(i + 1))) {
      var j = i + 1;
      while (j < n && (_isIdentPart(code.codeUnitAt(j)) || code[j] == '.')) {
        j++;
      }
      emit(i, j, TokenKind.decorator);
      continue;
    }
    // CSS hex colors (#fff, #1e1e1e)
    if (lang.cssProps && c == 35 /* # */) {
      var j = i + 1;
      while (j < n && j - i <= 8 && RegExp(r'[0-9a-fA-F]').hasMatch(code[j])) {
        j++;
      }
      if (j - i >= 4) {
        emit(i, j, TokenKind.number);
        continue;
      }
    }
    // Numbers
    if (_isDigit(c) || (c == 46 && i + 1 < n && _isDigit(code.codeUnitAt(i + 1)) && (i == 0 || !_isIdentPart(code.codeUnitAt(i - 1))))) {
      if (i > 0 && _isIdentPart(code.codeUnitAt(i - 1))) {
        i++;
        continue;
      }
      var j = i;
      if (c == 48 && j + 1 < n && (code[j + 1] == 'x' || code[j + 1] == 'X' || code[j + 1] == 'b' || code[j + 1] == 'B' || code[j + 1] == 'o')) {
        j += 2;
        while (j < n && (_isIdentPart(code.codeUnitAt(j)))) {
          j++;
        }
      } else {
        while (j < n && (_isDigit(code.codeUnitAt(j)) || code[j] == '_')) {
          j++;
        }
        if (j < n && code[j] == '.' && j + 1 < n && _isDigit(code.codeUnitAt(j + 1))) {
          j++;
          while (j < n && (_isDigit(code.codeUnitAt(j)) || code[j] == '_')) {
            j++;
          }
        }
        if (j < n && (code[j] == 'e' || code[j] == 'E')) {
          var k = j + 1;
          if (k < n && (code[k] == '+' || code[k] == '-')) k++;
          if (k < n && _isDigit(code.codeUnitAt(k))) {
            while (k < n && _isDigit(code.codeUnitAt(k))) {
              k++;
            }
            j = k;
          }
        }
        // CSS units (px, em, %, rem...) read as part of the number.
        if (lang.cssProps) {
          while (j < n && (_isIdentStart(code.codeUnitAt(j)) || code[j] == '%')) {
            j++;
          }
        }
      }
      emit(i, j, TokenKind.number);
      continue;
    }
    // Identifiers
    if (_isIdentStart(c)) {
      var j = i + 1;
      while (j < n && (_isIdentPart(code.codeUnitAt(j)) || (lang.cssProps && code[j] == '-'))) {
        j++;
      }
      final word = code.substring(i, j);
      final lookup = lang.caseInsensitive ? word.toLowerCase() : word;
      // Next non-space character decides function / property.
      var k = j;
      while (k < n && (code[k] == ' ' || code[k] == '\t')) {
        k++;
      }
      final next = k < n ? code[k] : '';
      final prev = i > 0 ? code[i - 1] : '';
      TokenKind? kind;
      if (lang.keywords.contains(lookup) && prev != '.') {
        kind = TokenKind.keyword;
      } else if (lang.constants.contains(lookup)) {
        kind = TokenKind.constant;
      } else if (lang.types.contains(lookup)) {
        kind = TokenKind.type;
      } else if (lang.jsonLike) {
        kind = null;
      } else if (lang.cssProps && next == ':' && (k + 1 >= n || code[k + 1] != ':')) {
        kind = TokenKind.property;
      } else if (lang.keyedLines && next == ':' && atLineStartKey(i)) {
        kind = TokenKind.property;
      } else if (next == '(') {
        kind = TokenKind.function;
      } else if (word.isNotEmpty && word.codeUnitAt(0) >= 65 && word.codeUnitAt(0) <= 90 && word.length > 1 && !lang.cssProps) {
        kind = TokenKind.type;
      } else if (prev == '.' && !lang.cssProps) {
        kind = TokenKind.property;
      }
      if (kind != null) {
        emit(i, j, kind);
      } else {
        i = j;
      }
      continue;
    }
    i++;
  }
  flushPlain(n);

  // JSON and YAML-style string keys: a string followed by ":" is a property, not a value.
  if (lang.jsonLike || lang.keyedLines) {
    for (var t = 0; t < out.length; t++) {
      if (out[t].kind != TokenKind.string) continue;
      var u = t + 1;
      while (u < out.length && out[u].kind == TokenKind.plain && out[u].text.trim().isEmpty) {
        u++;
      }
      if (u < out.length && out[u].kind == TokenKind.plain && out[u].text.trimLeft().startsWith(':')) {
        out[t] = CodeToken(out[t].text, TokenKind.property);
      }
    }
  }
  return _mergePlain(out);
}

/// HTML/XML: tags, attribute names, attribute values and comments.
List<CodeToken> _tokenizeMarkup(String code) {
  final out = <CodeToken>[];
  final n = code.length;
  var i = 0;
  var plainStart = 0;

  void flushPlain(int end) {
    if (end > plainStart) out.add(CodeToken(code.substring(plainStart, end), TokenKind.plain));
  }

  void emit(int start, int end, TokenKind kind) {
    flushPlain(start);
    out.add(CodeToken(code.substring(start, end), kind));
    plainStart = end;
    i = end;
  }

  while (i < n) {
    if (code.startsWith('<!--', i)) {
      final close = code.indexOf('-->', i + 4);
      emit(i, close == -1 ? n : close + 3, TokenKind.comment);
      continue;
    }
    if (code[i] == '<' && i + 1 < n && (code[i + 1] == '/' || code[i + 1] == '!' || code[i + 1] == '?' || _isIdentStart(code.codeUnitAt(i + 1)))) {
      // "<" or "</" then the tag name
      var j = i + 1;
      if (code[j] == '/' || code[j] == '!' || code[j] == '?') j++;
      while (j < n && (_isIdentPart(code.codeUnitAt(j)) || code[j] == '-' || code[j] == ':' || code[j] == '.')) {
        j++;
      }
      emit(i, j, TokenKind.tag);
      // attributes until the closing ">"
      while (i < n && code[i] != '>') {
        final ch = code[i];
        if (ch == '"' || ch == "'") {
          var k = i + 1;
          while (k < n && code[k] != ch) {
            k++;
          }
          emit(i, k < n ? k + 1 : n, TokenKind.string);
        } else if (_isIdentStart(code.codeUnitAt(i))) {
          var k = i + 1;
          while (k < n && (_isIdentPart(code.codeUnitAt(k)) || code[k] == '-' || code[k] == ':' || code[k] == '.' || code[k] == '@')) {
            k++;
          }
          emit(i, k, TokenKind.attribute);
        } else {
          i++;
        }
      }
      if (i < n) {
        // the closing ">" (and a preceding "/" or "?", which stay plain punctuation but belong to the tag)
        emit(i, i + 1, TokenKind.tag);
      }
      continue;
    }
    i++;
  }
  flushPlain(n);
  return _mergePlain(out);
}

/// Joins neighbouring plain tokens so the span list stays short.
List<CodeToken> _mergePlain(List<CodeToken> tokens) {
  final out = <CodeToken>[];
  for (final t in tokens) {
    if (out.isNotEmpty && out.last.kind == t.kind && t.kind == TokenKind.plain) {
      out[out.length - 1] = CodeToken(out.last.text + t.text, TokenKind.plain);
    } else {
      out.add(t);
    }
  }
  return out;
}

/// The colored text spans for [code], one TextSpan per token.
List<TextSpan> highlightSpans(String code, String language, TextStyle base, {CodeTheme theme = CodeTheme.dark}) {
  return <TextSpan>[
    for (final t in tokenize(code, language)) TextSpan(text: t.text, style: theme.styleOf(t.kind, base)),
  ];
}
