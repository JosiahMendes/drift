import 'package:drift/drift.dart';
import 'package:sqlparser/sqlparser.dart';

import '../../model/model.dart';

Map<SqlDialect, String> defaultConstraints(DriftColumn column) {
  final defaultConstraints = <String>[];
  final dialectSpecificConstraints = <SqlDialect, List<String>>{
    for (final dialect in SqlDialect.values) dialect: [],
  };

  var wrotePkConstraint = false;

  for (final feature in column.features) {
    if (feature is PrimaryKey) {
      if (!wrotePkConstraint) {
        defaultConstraints.add(feature is AutoIncrement
            ? 'PRIMARY KEY AUTOINCREMENT'
            : 'PRIMARY KEY');

        wrotePkConstraint = true;
        break;
      }
    }
  }

  if (!wrotePkConstraint) {
    for (final feature in column.features) {
      if (feature is UniqueKey) {
        defaultConstraints.add('UNIQUE');
        break;
      }
    }
  }

  for (final feature in column.features) {
    if (feature is ResolvedDartForeignKeyReference) {
      final tableName = '"${feature.otherTable.sqlName}"';
      final columnName = '"${feature.otherColumn.name.name}"';

      var constraint = 'REFERENCES $tableName ($columnName)';

      final onUpdate = feature.onUpdate;
      final onDelete = feature.onDelete;

      if (onUpdate != null) {
        constraint = '$constraint ON UPDATE ${onUpdate.description}';
      }

      if (onDelete != null) {
        constraint = '$constraint ON DELETE ${onDelete.description}';
      }

      defaultConstraints.add(constraint);
    } else if (feature is DefaultConstraintsFromSchemaFile) {
      // TODO: Dialect-specific constraints in schema file
      return {
        for (final dialect in SqlDialect.values)
          dialect: feature.defaultConstraints,
      };
    }
  }

  if (column.type == DriftSqlType.bool) {
    final name = '"${column.name.name}"';
    dialectSpecificConstraints[SqlDialect.sqlite]!
        .add('CHECK ($name IN (0, 1))');
  }

  for (final constraints in dialectSpecificConstraints.values) {
    constraints.addAll(defaultConstraints);
  }

  return dialectSpecificConstraints.map(
    (dialect, constraints) => MapEntry(dialect, constraints.join(' ')),
  );
}

extension on ReferenceAction {
  String get description {
    switch (this) {
      case ReferenceAction.setNull:
        return 'SET NULL';
      case ReferenceAction.setDefault:
        return 'SET DEFAULT';
      case ReferenceAction.cascade:
        return 'CASCADE';
      case ReferenceAction.restrict:
        return 'RESTRICT';
      case ReferenceAction.noAction:
        return 'NO ACTION';
    }
  }
}
