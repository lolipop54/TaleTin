library;

/// 仅用于尚未接入真实数据的界面演示（阅读页正文、目录、成就、设置等）。
/// 每接入一项真实数据就删除对应样例，不写入任何可复用组件。

/// 阅读演示书籍与章节（参考图 02/03/03-1）
class DemoChapter {
  const DemoChapter(this.title, this.paragraphs);
  final String title;
  final List<String> paragraphs;
}

const demoReadingBook = '山风与灯火';

const demoChapters = <DemoChapter>[
  DemoChapter('第三章 旧站台', [
    '从县城回来的那天，天色已经擦黑。车子在山道上转过最后一个弯时，我远远望见那座熟悉的旧站台，像一枚被岁月磨旧的印章，安静地卧在暮色里。',
    '站台很小，只有一条铁轨和一间低矮的候车室。屋檐下的灯还亮着，昏黄的光晕在风里轻轻摇晃，像是从很久以前就守在这里，等着谁的归来。风穿过空旷的月台，带着山里的凉意，也带着熟悉的草木气味。',
    '我走上前去，站在那盏灯下，忽然想起多年前的一个傍晚。那时我也是这样，一个人背着书包，在这里等一列慢车。那列车来得很晚，晚到我几乎以为它不会再来了。可是最终，它还是从黑暗的隧道里钻出来，带着一束温暖的灯光，停在了我的面前。',
    '有些等待，值得。',
  ]),
  DemoChapter('第十二章 雨夜', [
    '窗外的雨下得很大，像是从山的那一头倾泻而来，敲在屋顶上，又顺着檐角一串串地落下，汇成庭院里一片朦胧的水雾。',
    '我坐在桌前，听着雨声，手边是一盏昏黄的台灯。灯光照着书页，也照着窗玻璃上不断滑落的水痕。这样的夜晚，总让人想起很久以前的事，那些已经走远的人，和再也回不去的时光。',
    '山里一到下雨，便与外界隔绝了。电话没有信号，路也变得难走，只有雨声和偶尔的风声，提醒着这个世界还在不停地运转。可在这一刻，我竟觉得格外安心。仿佛所有的喧嚣都被雨水冲刷干净，只剩下自己，与这盏灯、这本书，和窗外无尽的黑夜。',
    '我泡了一杯热茶，茶香在空气中慢慢散开。书页已经有些发旧，边角微微卷起，但文字依然清晰，像老朋友的声音，在这样的雨夜里显得格外温柔。',
    '雨还在下。我不知道它会下到什么时候，但我并不着急。总有一些时刻，适合安静地等待。就像此刻，我愿意让时间慢下来，在这座小小的山居里，与自己对话，也与过去和解。',
  ]),
];

/// 目录结构：分卷 + 章节（参考图 03-1）
class DemoTocVolume {
  const DemoTocVolume(this.title, this.chapters);
  final String title;
  final List<String> chapters;
}

final demoToc = <DemoTocVolume>[
  const DemoTocVolume('第一卷', ['第一章 山路', '第二章 灯下', '第三章 旧站台', '第四章 雨夜']),
  DemoTocVolume('第二卷', List.generate(12, (i) => '第${_cn(i + 5)}章 待启程')),
];

const _cnDigits = ['一', '二', '三', '四', '五', '六', '七', '八', '九', '十',
  '十一', '十二', '十三', '十四', '十五', '十六'];
String _cn(int n) => _cnDigits[n - 1];

/// 笔记 / 书签条目（参考图 07）
enum DemoNoteKind { yellow, blue, text }

class DemoNote {
  const DemoNote(this.kind, this.quote, this.date, this.location);
  final DemoNoteKind kind;
  final String quote;
  final String date;
  final String location;

  String get kindLabel => switch (kind) {
        DemoNoteKind.yellow => '黄色标记',
        DemoNoteKind.blue => '蓝色标记',
        DemoNoteKind.text => '文字笔记',
      };
}

const demoNotes = <DemoNote>[
  DemoNote(DemoNoteKind.yellow, '有些等待，值得。', '9月17日', '第三章 旧站台'),
  DemoNote(DemoNoteKind.blue, '屋檐下的灯还亮着。', '9月12日', '第二章 灯下'),
  DemoNote(DemoNoteKind.text, '这里像是在写时间，而不只是站台。', '9月8日', '第一卷'),
];

/// 书签演示数据（综合面板「书签」页签）
const demoBookmarks = <DemoNote>[
  DemoNote(DemoNoteKind.text, '第三章 旧站台 · 站台很小，只有一条铁轨', '9月16日', '第三章 旧站台'),
  DemoNote(DemoNoteKind.text, '第一章 山路 · 天色已经擦黑', '9月11日', '第一章 山路'),
];

/// 成就页数据（参考图 04）
const demoAchievementStats = (
  today: '42分钟',
  week: '5小时18分',
  total: '186小时',
  streak: '17天',
);

const demoCalendarTitle = '2026年9月';
const demoCalendarCaption = '阅读，让平凡的日子发光';
const demoCalendarToday = 18;

/// 每日有效阅读分钟（未列出的日期为 0）
const demoReadingMinutes = <int, int>{
  1: 12, 2: 8, 5: 9, 6: 10, 8: 28, 10: 6,
  12: 32, 13: 30, 14: 22, 17: 31, 18: 42,
};

/// 阅读记录
const demoReadingRecords = (
  finishedBooks: '12本',
  longestOnce: '2小时06分',
  mostPerDay: '3小时42分',
  latestReading: '9月17日\n次日01:18',
);

const demoNoteCount = 48;

/// 听书面板（参考图 03-4）
