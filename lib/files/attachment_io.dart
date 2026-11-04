import 'dart:convert';
import 'dart:io';

import '../core/models.dart';

/// Reads a stored attachment as base64 for the provider request.
Future<String> base64Of(Attachment a) async {
  final bytes = await File(a.path).readAsBytes();
  return base64Encode(bytes);
}

/// The text a document contributes to the prompt.
String documentBlock(Attachment a) {
  return '[File: ${a.name}]\n${a.text}\n[End of file: ${a.name}]';
}
