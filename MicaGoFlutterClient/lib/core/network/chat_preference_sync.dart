import 'hidden_preference_sync.dart';

class ChatPreferenceSync extends HiddenPreferenceSync {
  ChatPreferenceSync({
    required super.cache,
    required super.api,
    required super.onChanged,
  }) : super(kind: HiddenPreferenceKind.chat);
}
