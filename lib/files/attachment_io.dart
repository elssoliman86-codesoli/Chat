import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/models.dart';

String _b64(List<int> bytes) => base64Encode(bytes);

/// Reads a stored attachment as base64 for the provider request. Big files are encoded off the UI thread.
Future<String> base64Of(Attachment a) async {
  final bytes = await File(a.path).readAsBytes();
  if (bytes.length < 400 * 1024) return base64Encode(bytes);
  return compute(_b64, bytes);
}

/// The text a document contributes to the prompt.
String documentBlock(Attachment a) {
  return '[File: ${a.name}]\n${a.text}\n[End of file: ${a.name}]';
}
