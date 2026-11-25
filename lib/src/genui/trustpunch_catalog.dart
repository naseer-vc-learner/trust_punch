import 'package:a2ui_core/a2ui_core.dart';
import 'package:a2ui_flutter/a2ui_flutter.dart';
import 'package:a2ui_flutter/basic_catalog.dart';
import 'package:flutter/material.dart';
import 'package:json_schema_builder/json_schema_builder.dart' hide ValidationResult;

/// TrustPunch's own A2UI components, offered beside the basic catalog.
///
/// An answer can only be built from components in a registered catalog, and
/// every payload is checked against the schema here before it renders. That
/// is the guard rail: whatever writes the answer, it cannot draw anything
/// this file does not define.
const trustPunchCatalogId =
    'https://trustpunch.local/catalogs/supervisor/v1.json';

/// The tones a tile or row may take. Anything else is refused by the schema.
const _tones = ['neutral', 'good', 'warning', 'alert'];

Color _toneColor(ColorScheme scheme, String? tone) => switch (tone) {
      'good' => scheme.primaryContainer,
      'warning' => const Color(0xFFFFE0B2),
      'alert' => scheme.errorContainer,
      _ => scheme.surfaceContainerHighest,
    };

/// One big number with a label: "3 · Working".
final _statTile = ComponentImplementation(
  name: 'StatTile',
  schema: Schema.object(
    properties: {
      'label': CommonSchemasV1.dynamicString,
      'value': CommonSchemasV1.dynamicString,
      'tone': Schema.string(enumValues: _tones),
      // Read by the basic Row to share its width between tiles.
      'weight': Schema.number(),
    },
    required: ['label', 'value'],
  ),
  builder: (context, node, props, buildChild) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Card(
      color: _toneColor(scheme, props.string('tone')),
      margin: const EdgeInsets.all(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              props.string('value') ?? '',
              style: text.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            Text(
              props.string('label') ?? '',
              style: text.labelMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  },
);

/// One person in an answer: name, one line of detail, a coloured edge.
final _workerRow = ComponentImplementation(
  name: 'WorkerRow',
  schema: Schema.object(
    properties: {
      'name': CommonSchemasV1.dynamicString,
      'detail': CommonSchemasV1.dynamicString,
      'tone': Schema.string(enumValues: _tones),
    },
    required: ['name'],
  ),
  builder: (context, node, props, buildChild) {
    final scheme = Theme.of(context).colorScheme;
    final name = props.string('name') ?? '';
    final detail = props.string('detail');
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: ListTile(
        dense: true,
        leading: CircleAvatar(
          backgroundColor: _toneColor(scheme, props.string('tone')),
          child: Text(name.isEmpty ? '?' : name.characters.first),
        ),
        title: Text(name),
        subtitle: detail == null || detail.isEmpty ? null : Text(detail),
      ),
    );
  },
);

CatalogImplementation trustPunchCatalog() => CatalogImplementation(
      id: trustPunchCatalogId,
      protocolVersion: A2uiProtocolVersion.v1_0,
      components: [_statTile, _workerRow],
    );

/// How strictly answers are checked before anything renders.
///
/// `MessageProcessor` checks nothing beyond schemas unless given a config,
/// and then lets unknown component types through. This turns every check
/// on, allows only the three messages an answer needs (no data-model writes,
/// no function calls), and caps nesting so an oversized layout is refused
/// rather than slowing the phone.
const askValidation = ValidationConfig(
  allowedMessages: ['createSurface', 'updateComponents', 'deleteSurface'],
  maxDepth: 12,
);

/// The one way the app builds a processor for answers, so the screen and the
/// tests always run with the same catalogs and the same checks.
MessageProcessor<ComponentImplementation> newAskProcessor() =>
    MessageProcessor<ComponentImplementation>(
      catalogs: [basicCatalog(), trustPunchCatalog()],
      validationConfig: askValidation,
    );
