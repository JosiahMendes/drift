import 'package:sqlparser/sqlparser.dart';
import 'package:sqlparser/src/reader/parser.dart';
import 'package:sqlparser/src/reader/tokenizer/scanner.dart';
import 'package:sqlparser/src/utils/ast_equality.dart';
import 'package:test/test.dart';

import 'utils.dart';

void main() {
  test('can parse multiple statements', () {
    const sql = 'a: UPDATE tbl SET a = b; b: SELECT * FROM tbl;';

    testDriftFile(
      sql,
      DriftFile([
        DeclaredStatement(
          SimpleName('a'),
          UpdateStatement(
            table: TableReference('tbl'),
            set: [
              SetComponent(
                column: Reference(columnName: 'a'),
                expression: Reference(columnName: 'b'),
              ),
            ],
          ),
        ),
        DeclaredStatement(
          SimpleName('b'),
          SelectStatement(
            columns: [StarResultColumn(null)],
            from: TableReference('tbl'),
          ),
        ),
      ]),
    );
  });

  test('recovers from invalid statements', () {
    const sql = 'a: UPDATE tbl SET a = * d; b: SELECT * FROM tbl;';
    final tokens = Scanner(sql).scanTokens();
    final statements = Parser(tokens).driftFile().statements;

    expect(statements, hasLength(1));
    enforceEqual(
      statements[0],
      DeclaredStatement(
        SimpleName('b'),
        SelectStatement(
          columns: [StarResultColumn(null)],
          from: TableReference('tbl'),
        ),
      ),
    );
  });

  test('parses imports and declared statements in drift mode', () {
    const sql = r'''
    import 'test.dart';
    query: SELECT * FROM tbl;
     ''';

    final tokens = Scanner(sql, scanDriftTokens: true).scanTokens();
    final statements = Parser(tokens, useDrift: true).driftFile().statements;

    expect(statements, hasLength(2));

    final parsedImport = statements[0] as ImportStatement;
    enforceEqual(parsedImport, ImportStatement('test.dart'));
    expect(parsedImport.importToken, tokens[0]);
    expect(parsedImport.importString, tokens[1]);
    expect(parsedImport.semicolon, tokens[2]);

    final declared = statements[1] as DeclaredStatement;
    enforceEqual(
      declared,
      DeclaredStatement(
        SimpleName('query'),
        SelectStatement(
          columns: [StarResultColumn(null)],
          from: TableReference('tbl'),
        ),
      ),
    );
  });
}
