import 'dart:io';

import 'package:ftp_server/file_operations/physical_file_operations.dart';
import 'package:ftp_server/ftp_server.dart';
import 'package:ftp_server/server_type.dart';
import 'package:path_provider/path_provider.dart';

import '../core/models.dart';

/// A local FTP server over the Projects folder, so a person can edit those files directly from
/// another device on the same network (a PC's file manager, FileZilla, WinSCP, ...) instead of only
/// through this app. Off until the person turns it on; reaches only the Projects folder, not the
/// rest of the app's own files.
class FtpService {
  FtpService._();
  static final FtpService instance = FtpService._();

  FtpServer? _server;
  int? _port;

  bool get running => _server != null;
  int? get port => _port;

  /// The folder being served — <app documents>/projects, the same folder the in-app Projects
  /// workspace itself reads and writes.
  Future<Directory> projectsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}/projects');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// This device's own local-network IPv4 addresses (Wi-Fi, typically), for showing the person what
  /// to type on the other device — loopback and link-local addresses are not useful for that, so
  /// they're left out.
  Future<List<String>> localAddresses() async {
    final out = <String>[];
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      for (final i in interfaces) {
        for (final a in i.addresses) {
          if (!a.isLoopback && !a.address.startsWith('169.254.')) out.add(a.address);
        }
      }
    } catch (_) {}
    return out;
  }

  /// Starts the server, or returns an error message instead (most commonly the port already being
  /// in use by something else on the device).
  Future<String?> start({required int port, String? username, String? password}) async {
    if (running) return null;
    final dir = await projectsDir();
    try {
      final server = FtpServer(
        port,
        fileOperations: PhysicalFileOperations(dir.path),
        serverType: ServerType.readAndWrite,
        username: (username == null || username.isEmpty) ? null : username,
        password: (password == null || password.isEmpty) ? null : password,
      );
      await server.start();
      _server = server;
      _port = port;
      return null;
    } catch (e) {
      _server = null;
      _port = null;
      return e.toString();
    }
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _port = null;
    if (server != null) {
      try {
        await server.stop();
      } catch (_) {}
    }
  }

  /// Called once at app startup: if the person had it on last time, start it again silently — a
  /// fresh app launch means it is not actually running yet even though the setting says on. Any
  /// failure (e.g. the saved port is taken by something else now) is left for the Plugins screen to
  /// surface the next time it's opened, rather than blocking startup on it.
  Future<void> ensureStartedIfEnabled(AppSettings settings) async {
    if (!settings.ftpEnabled || running) return;
    await start(port: settings.ftpPort, username: settings.ftpUsername, password: settings.ftpPassword);
  }
}
