import '../../../domain/models/locator.dart';
import '../../../domain/models/speech_unit.dart';
import '../../../domain/services/tts_engine.dart';
import '../../../engine/normalization/locator_mapper.dart';

sealed class ListeningEngineAction {
  const ListeningEngineAction();
}

class IgnoreListeningEvent extends ListeningEngineAction {
  const IgnoreListeningEvent();
}

class ConfirmListeningStart extends ListeningEngineAction {
  const ConfirmListeningStart(this.position);
  final Locator position;
}

class ConfirmListeningRange extends ListeningEngineAction {
  const ConfirmListeningRange(this.offset, this.position);
  final int offset;
  final Locator position;
}

class CompleteListeningUnit extends ListeningEngineAction {
  const CompleteListeningUnit();
}

class FailListeningUnit extends ListeningEngineAction {
  const FailListeningUnit(this.code);
  final TtsFailureCode code;
}

class StopListeningUnit extends ListeningEngineAction {
  const StopListeningUnit();
}

/// 将原生事件解析成无副作用的内部动作；任务版本与动作执行仍由控制器决定。
ListeningEngineAction parseListeningEngineEvent({
  required TtsEngineEvent event,
  required String? activeId,
  required bool desiredPlaying,
  required bool started,
  required int sentOffset,
  required int resumeOffset,
  required SpeechUnit? unit,
}) {
  if (event.id != activeId || !desiredPlaying) {
    return const IgnoreListeningEvent();
  }
  if (unit == null) return const IgnoreListeningEvent();
  if (event is TtsStartedEvent) {
    return started
        ? const IgnoreListeningEvent()
        : ConfirmListeningStart(listeningPosition(unit, sentOffset));
  }
  if (event is TtsRangeEvent && started) {
    if (event.start < 0 ||
        event.end > unit.text.length - sentOffset ||
        event.start >= event.end) {
      return const IgnoreListeningEvent();
    }
    final offset = snapToGrapheme(unit.text, sentOffset + event.start);
    return offset < resumeOffset
        ? const IgnoreListeningEvent()
        : ConfirmListeningRange(offset, listeningPosition(unit, offset));
  }
  if (event is TtsDoneEvent) return const CompleteListeningUnit();
  if (event is TtsFailedEvent) return FailListeningUnit(event.code);
  if (event is TtsStoppedEvent) return const StopListeningUnit();
  return const IgnoreListeningEvent();
}

Locator listeningPosition(SpeechUnit unit, int offset) =>
    offset == 0 || unit.isChapterTitle
    ? unit.startLocator
    : unit.startLocator.copyWith(
        utf16Offset: unit.startLocator.utf16Offset + offset,
        exact: unit.text.substring(
          offset,
          snapToGrapheme(unit.text, offset + 32),
        ),
        prefix: '',
        suffix: '',
      );
