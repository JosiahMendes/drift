import 'package:drift/drift.dart';
import 'package:drift_dev/moor_generator.dart';
import 'package:drift_dev/src/analyzer/options.dart';
import 'package:recase/recase.dart';
import 'package:sqlparser/sqlparser.dart';

import '../../writer/utils/column_constraints.dart';

const _infoVersion = '1.0.0';

/// Utilities to transform moor schema entities to json.
class SchemaWriter {
  /// The parsed and resolved database for which the schema should be written.
  final Database db;

  final DriftOptions options;

  final Map<DriftSchemaEntity, int> _entityIds = {};
  int _maxId = 0;

  SchemaWriter(this.db, {this.options = const DriftOptions.defaults()});

  int _idOf(DriftSchemaEntity entity) {
    return _entityIds.putIfAbsent(entity, () => _maxId++);
  }

  Map<String, dynamic> createSchemaJson() {
    return {
      '_meta': {
        'description': 'This file contains a serialized version of schema '
            'entities for drift.',
        'version': _infoVersion,
      },
      'options': _serializeOptions(),
      'entities': [
        for (final entity in db.entities) _entityToJson(entity),
      ],
    };
  }

  Map _serializeOptions() {
    const relevantKeys = {'store_date_time_values_as_text'};
    final asJson = options.toJson()
      ..removeWhere((key, _) => !relevantKeys.contains(key));

    return asJson;
  }

  Map _entityToJson(DriftSchemaEntity entity) {
    String type;
    Map data;

    if (entity is DriftTable) {
      type = 'table';
      data = _tableData(entity);
    } else if (entity is MoorTrigger) {
      type = 'trigger';
      data = {
        'on': _idOf(entity.on!),
        'refences_in_body': [
          for (final ref in entity.bodyReferences) _idOf(ref),
        ],
        'name': entity.displayName,
        'sql': entity.createSql(options),
      };
    } else if (entity is MoorIndex) {
      type = 'index';
      data = {
        'on': _idOf(entity.table!),
        'name': entity.name,
        'sql': entity.createStmt,
      };
    } else if (entity is MoorView) {
      if (entity.declaration is! DriftViewDeclaration) {
        throw UnsupportedError(
            'Exporting Dart-defined views into a schema is not '
            'currently supported');
      }

      type = 'view';
      data = {
        'name': entity.name,
        'sql': entity.createSql(const DriftOptions.defaults()),
        'dart_data_name': entity.dartTypeName,
        'dart_info_name': entity.entityInfoName,
        'columns': [for (final column in entity.columns) _columnData(column)],
      };
    } else if (entity is SpecialQuery) {
      type = 'special-query';
      data = {
        'scenario': 'create',
        'sql': entity.sql,
      };
    } else {
      throw AssertionError('unknown entity type $entity');
    }

    return {
      'id': _idOf(entity),
      'references': [
        for (final reference in entity.references)
          if (reference != entity) _idOf(reference),
      ],
      'type': type,
      'data': data,
    };
  }

  Map _tableData(DriftTable table) {
    return {
      'name': table.sqlName,
      'was_declared_in_moor': table.isFromSql,
      'columns': [for (final column in table.columns) _columnData(column)],
      'is_virtual': table.isVirtualTable,
      if (table.isVirtualTable) 'create_virtual_stmt': table.createVirtual,
      if (table.overrideWithoutRowId != null)
        'without_rowid': table.overrideWithoutRowId,
      if (table.overrideTableConstraints != null)
        'constraints': table.overrideTableConstraints,
      if (table.primaryKey != null)
        'explicit_pk': [...table.primaryKey!.map((c) => c.name.name)],
      if (table.uniqueKeys != null && table.uniqueKeys!.isNotEmpty)
        'unique_keys': [
          for (final uniqueKey
              in table.uniqueKeys ?? const <Set<DriftColumn>>[])
            [for (final column in uniqueKey) column.name.name],
        ]
    };
  }

  Map _columnData(DriftColumn column) {
    final constraints = defaultConstraints(column);

    return {
      'name': column.name.name,
      'getter_name': column.dartGetterName,
      'moor_type': column.type.toSerializedString(),
      'nullable': column.nullable,
      'customConstraints': column.customConstraints,
      if (constraints[SqlDialect.sqlite]!.isNotEmpty &&
          column.customConstraints == null)
        // TODO: Dialect-specific constraints in schema file
        'defaultConstraints': constraints[SqlDialect.sqlite]!,
      'default_dart': column.defaultArgument,
      'default_client_dart': column.clientDefaultCode,
      'dsl_features': [...column.features.map(_dslFeatureData)],
      if (column.typeConverter != null)
        'type_converter': {
          'dart_expr': column.typeConverter!.expression,
          'dart_type_name': column.typeConverter!.dartType
              .getDisplayString(withNullability: false),
        }
    };
  }

  dynamic _dslFeatureData(ColumnFeature feature) {
    if (feature is AutoIncrement) {
      return 'auto-increment';
    } else if (feature is PrimaryKey) {
      return 'primary-key';
    } else if (feature is LimitingTextLength) {
      return {
        'allowed-lengths': {
          'min': feature.minLength,
          'max': feature.maxLength,
        },
      };
    }
    return 'unknown';
  }
}

/// Reads files generated by [SchemaWriter].
class SchemaReader {
  final Map<int, DriftSchemaEntity> _entitiesById = {};
  final Map<int, Map<String, dynamic>> _rawById = {};

  final Set<int> _currentlyProcessing = {};

  final SqlEngine _engine = SqlEngine();
  Map<String, Object?> options = const {};

  SchemaReader._();

  factory SchemaReader.readJson(Map<String, dynamic> json) {
    return SchemaReader._().._read(json);
  }

  Iterable<DriftSchemaEntity> get entities => _entitiesById.values;

  void _read(Map<String, dynamic> json) {
    // Read drift options if they are part of the schema file.
    final optionsInJson = json['options'] as Map<String, Object?>?;
    options = optionsInJson ??
        {
          'store_date_time_values_as_text': false,
        };

    final entities = json['entities'] as List<dynamic>;

    for (final raw in entities) {
      final rawData = raw as Map<String, dynamic>;
      final id = rawData['id'] as int;

      _rawById[id] = rawData;
    }

    _rawById.keys.forEach(_processById);
  }

  T _existingEntity<T extends DriftSchemaEntity>(dynamic id) {
    return _entitiesById[id as int] as T;
  }

  void _processById(int id) {
    if (_entitiesById.containsKey(id)) return;
    if (_currentlyProcessing.contains(id)) {
      throw ArgumentError(
          'Could not read schema file: Contains circular references.');
    }

    _currentlyProcessing.add(id);

    final rawData = _rawById[id];
    final references = (rawData?['references'] as List<dynamic>).cast<int>();

    // Ensure that dependencies have been resolved
    references.forEach(_processById);

    final content = rawData?['data'] as Map<String, dynamic>;
    final type = rawData?['type'] as String;

    DriftSchemaEntity entity;
    switch (type) {
      case 'index':
        entity = _readIndex(content);
        break;
      case 'trigger':
        entity = _readTrigger(content);
        break;
      case 'table':
        entity = _readTable(content);
        break;
      case 'view':
        entity = _readView(content);
        break;
      case 'special-query':
        // Not relevant for the schema.
        return;
      default:
        throw ArgumentError(
            'Could not read schema file: Unknown entity $rawData');
    }

    _entitiesById[id] = entity;
  }

  MoorIndex _readIndex(Map<String, dynamic> content) {
    final on = _existingEntity<DriftTable>(content['on']);
    final name = content['name'] as String;
    final sql = content['sql'] as String;

    return MoorIndex(name, const CustomIndexDeclaration(), sql, on);
  }

  MoorTrigger _readTrigger(Map<String, dynamic> content) {
    final on = _existingEntity<DriftTable>(content['on']);
    final name = content['name'] as String;
    final sql = content['sql'] as String;

    final trigger = MoorTrigger(name, CustomTriggerDeclaration(sql), on);
    for (final bodyRef in content['refences_in_body'] as List) {
      trigger.bodyReferences.add(_existingEntity(bodyRef));
    }
    return trigger;
  }

  DriftTable _readTable(Map<String, dynamic> content) {
    final sqlName = content['name'] as String;
    final isVirtual = content['is_virtual'] as bool;
    final withoutRowId = content['without_rowid'] as bool?;
    final pascalCase = ReCase(sqlName).pascalCase;
    final columns = [
      for (final rawColumn in content['columns'] as List)
        _readColumn(rawColumn as Map<String, dynamic>)
    ];

    if (isVirtual) {
      final create = content['create_virtual_stmt'] as String;
      final parsed =
          _engine.parse(create).rootNode as CreateVirtualTableStatement;

      return DriftTable(
        sqlName: sqlName,
        dartTypeName: '${pascalCase}Data',
        overriddenName: pascalCase,
        declaration: CustomVirtualTableDeclaration(parsed),
        overrideWithoutRowId: withoutRowId,
        overrideDontWriteConstraints: true,
        columns: columns,
      );
    }

    List<String>? tableConstraints;
    if (content.containsKey('constraints')) {
      tableConstraints = (content['constraints'] as List<dynamic>).cast();
    }

    Set<DriftColumn>? explicitPk;
    if (content.containsKey('explicit_pk')) {
      explicitPk = {
        for (final columnName in content['explicit_pk'] as List<dynamic>)
          columns.singleWhere((c) => c.name.name == columnName)
      };
    }

    List<Set<DriftColumn>> uniqueKeys = [];
    if (content.containsKey('unique_keys')) {
      for (final key in content['unique_keys']) {
        uniqueKeys.add({
          for (final columnName in key)
            columns.singleWhere((c) => c.name.name == columnName)
        });
      }
    }

    return DriftTable(
      sqlName: sqlName,
      overriddenName: pascalCase,
      columns: columns,
      dartTypeName: '${pascalCase}Data',
      primaryKey: explicitPk,
      uniqueKeys: uniqueKeys,
      overrideTableConstraints: tableConstraints,
      overrideDontWriteConstraints: content['was_declared_in_moor'] as bool?,
      overrideWithoutRowId: withoutRowId,
      declaration: const CustomTableDeclaration(),
    );
  }

  MoorView _readView(Map<String, dynamic> content) {
    return MoorView(
      declaration: null,
      name: content['name'] as String,
      dartTypeName: content['dart_data_name'] as String,
      entityInfoName: content['dart_info_name'] as String,
    )..columns = [
        for (final column in content['columns'])
          _readColumn(column as Map<String, dynamic>)
      ];
  }

  DriftColumn _readColumn(Map<String, dynamic> data) {
    final name = data['name'] as String;
    final columnType =
        _SerializeSqlType.deserialize(data['moor_type'] as String);
    final nullable = data['nullable'] as bool;
    final customConstraints = data['customConstraints'] as String?;
    final defaultConstraints = data['defaultConstraints'] as String?;
    final dslFeatures = [
      for (final feature in data['dsl_features'] as List<dynamic>)
        _columnFeature(feature),
      if (defaultConstraints != null)
        DefaultConstraintsFromSchemaFile(defaultConstraints),
    ];
    final getterName = data['getter_name'] as String?;

    // Note: Not including client default code because that usually depends on
    // imports from the database.
    return DriftColumn(
      name: ColumnName.explicitly(name),
      dartGetterName: getterName ?? ReCase(name).camelCase,
      type: columnType,
      nullable: nullable,
      defaultArgument: data['default_dart'] as String?,
      customConstraints: customConstraints,
      features: dslFeatures.whereType<ColumnFeature>().toList(),
    );
  }

  ColumnFeature? _columnFeature(dynamic data) {
    if (data == 'auto-increment') return AutoIncrement();
    if (data == 'primary-key') return const PrimaryKey();

    if (data is Map<String, dynamic>) {
      final allowedLengths = data['allowed-lengths'] as Map<String, dynamic>;
      return LimitingTextLength(
        minLength: allowedLengths['min'] as int?,
        maxLength: allowedLengths['max'] as int?,
      );
    }

    return null;
  }
}

// There used to be another enum to represent columns that has since been
// replaced with DriftSqlType. We still need to reflect the old description in
// the serialized format.
extension _SerializeSqlType on DriftSqlType {
  static DriftSqlType deserialize(String description) {
    switch (description) {
      case 'ColumnType.boolean':
        return DriftSqlType.bool;
      case 'ColumnType.text':
        return DriftSqlType.string;
      case 'ColumnType.bigInt':
        return DriftSqlType.bigInt;
      case 'ColumnType.integer':
        return DriftSqlType.int;
      case 'ColumnType.datetime':
        return DriftSqlType.dateTime;
      case 'ColumnType.blob':
        return DriftSqlType.blob;
      case 'ColumnType.real':
        return DriftSqlType.double;
      default:
        throw ArgumentError.value(
            description, 'description', 'Not a known column type');
    }
  }

  String toSerializedString() {
    switch (this) {
      case DriftSqlType.bool:
        return 'ColumnType.boolean';
      case DriftSqlType.string:
        return 'ColumnType.text';
      case DriftSqlType.bigInt:
        return 'ColumnType.bigInt';
      case DriftSqlType.int:
        return 'ColumnType.integer';
      case DriftSqlType.dateTime:
        return 'ColumnType.datetime';
      case DriftSqlType.blob:
        return 'ColumnType.blob';
      case DriftSqlType.double:
        return 'ColumnType.real';
    }
  }
}
