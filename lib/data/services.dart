import '../files/attachment_service.dart';
import 'app_store.dart';
import 'chat_engine.dart';

/// App-wide objects. One user, one phone: simple globals are enough.
final AppStore store = AppStore();
final ChatEngine engine = ChatEngine(store);
final AttachmentService attachments = AttachmentService();
