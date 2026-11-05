import 'project_server.dart';
import 'project_store.dart';

/// The folders of files the assistant builds, and the local web server that runs them.
final ProjectStore projects = ProjectStore();
final ProjectServer projectServer = ProjectServer(projects);
