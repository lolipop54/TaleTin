import '../../domain/services/listening_deadline.dart';
import 'native_tts_channel.dart';

class NativeListeningDeadline implements ListeningDeadline {
  NativeListeningDeadline(this.channel);
  final NativeTtsChannel channel;
  @override
  Future<int> now() => channel.elapsedRealtime();
  @override
  Future<void> arm(int version, int? deadlineMs) =>
      channel.setSleepDeadline(version, deadlineMs);
  @override
  Stream<int> get expired => channel.deadlines;
}
