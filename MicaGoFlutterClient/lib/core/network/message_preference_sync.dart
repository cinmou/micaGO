import 'hidden_preference_sync.dart';

class MessagePreferenceSync extends HiddenPreferenceSync {
  MessagePreferenceSync({
    required super.cache,
    required super.api,
    required super.onChanged,
  }) : super(kind: HiddenPreferenceKind.message);
}
