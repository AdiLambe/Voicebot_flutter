// IRA Service Desk - Flutter voicebot app.
//
// Flow: Incoming call -> Green / Red / YELLOW swipe -> voicebot sawaal puchta hai (TTS),
// jawab sunke note karta hai (STT) -> last mein WhatsApp photos message -> ticket "Open".
// Tickets manually Open -> In progress -> Completed. Completed 20 din baad auto-clear.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import 'core.dart';
import 'phone.dart';

const bg = Color(0xFF121318);
const card = Color(0xFF1A1C23);
const inputBg = Color(0xFF23252E);
const border = Color(0xFF2C2F39);
const yellow = Color(0xFFF59E0B);
const yellowDim = Color(0xFF3A2A10);
const yellowTxt = Color(0xFFFCD34D);
const muted = Color(0xFF9CA3AF);
const green = Color(0xFF10B981);
const blue = Color(0xFF3B82F6);
const red = Color(0xFFEF4444);
const dark = Color(0xFF111111);
const statusColor = {'open': yellow, 'in_progress': blue, 'completed': green};

final messengerKey = GlobalKey<ScaffoldMessengerState>();

void toast(String msg) {
  messengerKey.currentState?.showSnackBar(
    SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // App band hone ki jagah error screen
  ErrorWidget.builder = (d) =>
      ErrorScreen(text: '${d.exception}\n\n${d.stack}');
  runZonedGuarded(
    () async {
      final store = await Store.open();
      final state = AppState(store);
      runApp(IraApp(state: state));
      unawaited(state.start());
    },
    (e, st) {
      debugPrint('ERROR $e\n$st');
      toast('Error: $e');
    },
  );
}

// =====================================================================
//  State + bot logic
// =====================================================================
enum Mode { idle, ringing, bot, done }

class AppState extends ChangeNotifier {
  AppState(this.store);

  final Store store;
  final Voice voice = Voice();

  int tab = 0;
  String? openTicketId;

  Mode mode = Mode.idle;
  bool real = false;
  String caller = '';
  int step = 0;
  int seconds = 0;
  int tries = 0;
  String stateText = '';
  String questionText = '';
  String heardText = '';
  final inputs = {for (final q in questions) q.key: TextEditingController()};
  final callerCtl = TextEditingController();
  final demoNumberCtl = TextEditingController();

  Timer? _timer;
  int _gen = 0; // purane async kaam cancel karne ke liye
  int _lastCallTs = 0;

  Future<void> start() async {
    await voice.init();
    if (isAndroid) {
      // app khulte waqt jo call pehle se ring ho rahi hai uska screen na dikhaye
      final st = await Phone.callState();
      if (st != null && st['state'] != 'RINGING') {
        _lastCallTs = (st['ts'] ?? 0) as int;
      }
      Timer.periodic(const Duration(milliseconds: 500), (_) => _checkCall());
    }
    Timer.periodic(const Duration(hours: 1), (_) => store.purgeCompleted());
  }

  void go(int t) {
    tab = t;
    if (t != 1) openTicketId = null;
    notifyListeners();
  }

  void openTicket(String id) {
    tab = 1;
    openTicketId = id;
    notifyListeners();
  }

  Future<void> say(String text) {
    final pitch = double.tryParse(store.cfg('voice_pitch')) ?? 0.7;
    final rate = double.tryParse(store.cfg('voice_rate')) ?? 0.45;
    return voice.speak(
      text,
      lang: store.cfg('tts_language'),
      pitch: pitch,
      rate: rate,
    );
  }

  // ---------- asli call watcher (CallReceiver.kt -> MainActivity.kt) ----------
  Future<void> _checkCall() async {
    final st = await Phone.callState();
    if (st == null) return;
    final state = st['state'] as String? ?? 'IDLE';
    final number = st['number'] as String? ?? '';
    final ts = (st['ts'] ?? 0) as int;
    if (state == 'RINGING' &&
        ts != _lastCallTs &&
        (mode == Mode.idle || mode == Mode.done)) {
      _lastCallTs = ts;
      tab = 0;
      showRinging(number, real: true);
    } else if (state == 'RINGING' &&
        mode == Mode.ringing &&
        number.isNotEmpty &&
        caller.isEmpty) {
      caller = number;
      notifyListeners();
    } else if (state == 'OFFHOOK' && real && mode == Mode.ringing) {
      showIdle(); // client ne phone ka apna green button daba diya
    } else if (state == 'IDLE' &&
        real &&
        (mode == Mode.ringing || mode == Mode.bot)) {
      if (mode == Mode.ringing) {
        showIdle();
      } else {
        toast(
          'Customer ne call kaat di - jo note hua uska ticket ban raha hai',
        );
        finish(hungUp: true);
      }
    }
  }

  // ---------- idle / ringing ----------
  void showIdle({bool stopVoice = true}) {
    _gen++;
    if (stopVoice) voice.stop();
    _timer?.cancel();
    mode = Mode.idle;
    notifyListeners();
  }

  void showRinging(String number, {required bool real}) {
    caller = number;
    this.real = real;
    mode = Mode.ringing;
    notifyListeners();
  }

  Future<void> decline() async {
    if (real) await Phone.end();
    showIdle();
  }

  Future<void> answerSelf() async {
    if (real) {
      await Phone.answer();
      await Phone.toBack();
    }
    showIdle();
  }

  // ---------- voicebot ----------
  Future<void> startBot() async {
    mode = Mode.bot;
    step = 0;
    seconds = 0;
    for (final c in inputs.values) {
      c.clear();
    }
    callerCtl.text = caller;
    stateText = 'Call connect ho raha hai...';
    questionText = '';
    heardText = '';
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      seconds++;
      notifyListeners();
    });
    notifyListeners();
    if (real) {
      await Phone.answer();
      await Future.delayed(const Duration(milliseconds: 1200));
      await Phone.speaker(true); // bot ki awaaz customer tak speaker se
      await Future.delayed(const Duration(milliseconds: 800));
    } else {
      await Future.delayed(const Duration(milliseconds: 400));
    }
    if (mode == Mode.bot) ask();
  }

  Future<void> ask({bool retry = false}) async {
    if (mode != Mode.bot || step >= questions.length) return;
    final gen = ++_gen;
    final q = questions[step];
    if (!retry) tries = 0;
    questionText = '"${q.text}"';
    stateText = 'Bot bol raha hai...  (${step + 1}/${questions.length})';
    heardText = '';
    notifyListeners();
    await say(retry ? sorryMessage : q.text);
    if (gen != _gen || mode != Mode.bot) return;
    await listen(gen);
  }

  Future<void> listen([int? gen]) async {
    if (mode != Mode.bot || step >= questions.length) return;
    gen ??= ++_gen;
    stateText = 'Sun raha hai...';
    notifyListeners();
    final text = await voice.listen(localeId: store.cfg('stt_language'));
    if (gen != _gen || mode != Mode.bot) return;
    onHeard(text);
  }

  void onHeard(String? text) {
    if (mode != Mode.bot || step >= questions.length) return;
    final key = questions[step].key;
    if (text != null && text.trim().isNotEmpty) {
      inputs[key]!.text = text;
      heardText = 'Note kiya: $text';
      notifyListeners();
      final gen = _gen;
      Future.delayed(const Duration(milliseconds: 1200), () {
        if (gen == _gen) nextQ();
      });
    } else if (voice.canListen && tries < (real ? 1 : 2)) {
      tries++;
      ask(retry: true); // "Maaf kijiye sir, samajh nahi aaya..."
    } else {
      stateText = 'Jawab type karo, phir Next';
      heardText = '(Awaaz nahi mili - Mic dabao ya type karo)';
      notifyListeners();
    }
  }

  void nextQ() {
    _gen++;
    voice.stop();
    step++;
    if (step < questions.length) {
      ask();
    } else {
      finish();
    }
  }

  Future<void> finish({bool hungUp = false}) async {
    if (mode != Mode.bot) return;
    _gen++;
    mode = Mode.done;
    _timer?.cancel();
    await voice.stop();
    step = questions.length;
    final answers = {for (final e in inputs.entries) e.key: e.value.text};
    stateText = 'Ticket ban gaya';
    final t = await store.createTicket(answers, callerCtl.text);
    toast('Ticket ${t.id} ban gaya (Open)');
    if (!hungUp) {
      questionText = '"$finalMessage"';
      notifyListeners();
      await say(finalMessage); // last message - hard coded
      if (real) {
        await Future.delayed(const Duration(seconds: 1));
        await Phone.end(); // bot ke baad call khud kaat do
        await Phone.speaker(false);
      }
    }
    mode = Mode.idle;
    openTicket(t.id);
  }

  Future<void> endWithoutTicket() async {
    if (real) {
      await Phone.end();
      await Phone.speaker(false);
    }
    showIdle();
  }

  // ---------- ticket actions ----------
  Future<void> setStatus(Ticket t, String s) async {
    await store.setStatus(t.id, s);
    notifyListeners();
  }

  Future<void> togglePhotos(Ticket t) async {
    t.photosReceived = !t.photosReceived;
    await store.touch(t);
    notifyListeners();
  }

  Future<void> sendWhatsapp(Ticket t) async {
    if (t.callerNumber.trim().isEmpty) {
      toast('Caller number nahi hai');
      return;
    }
    if (store.cfg('whatsapp_mode') == 'cloud_api') {
      toast('Bhej raha hoon...');
      final (ok, msg) = await store.sendWhatsappCloud(t);
      toast(msg);
      if (!ok) return;
    } else {
      await launchUrl(
        store.whatsappLink(t),
        mode: LaunchMode.externalApplication,
      );
    }
    t.whatsappSent++;
    await store.touch(t);
    notifyListeners();
  }

  Future<void> callBack(Ticket t) =>
      launchUrl(Uri(scheme: 'tel', path: t.callerNumber.replaceAll(' ', '')));

  Future<void> deleteTicket(Ticket t) async {
    await store.delete(t.id);
    openTicketId = null;
    notifyListeners();
  }

  Future<void> saveConfig(Map<String, String> values) async {
    store.config.addAll(values);
    await store.saveConfig();
    toast('Config save ho gaya');
    notifyListeners();
  }
}

// =====================================================================
//  App shell
// =====================================================================
class IraApp extends StatelessWidget {
  const IraApp({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'IRA Service Desk',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: messengerKey,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: bg,
        colorScheme: const ColorScheme.dark(primary: yellow, surface: card),
      ),
      home: ListenableBuilder(
        listenable: state,
        builder: (context, _) => Shell(state: state),
      ),
    );
  }
}

class Shell extends StatelessWidget {
  const Shell({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final pages = [
      CallPage(s: state),
      state.openTicketId == null
          ? TicketsPage(s: state)
          : DetailPage(s: state, id: state.openTicketId!),
      SettingsPage(s: state),
      SetupPage(s: state),
    ];
    return PopScope(
      canPop: state.tab == 0 && state.openTicketId == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (state.openTicketId != null) {
          state.openTicketId = null;
          state.go(1);
        } else {
          state.go(0);
        }
      },
      child: Scaffold(
        body: SafeArea(child: pages[state.tab]),
        bottomNavigationBar: SafeArea(
          child: Container(
            height: 66,
            decoration: const BoxDecoration(
              color: bg,
              border: Border(top: BorderSide(color: border)),
            ),
            padding: const EdgeInsets.all(6),
            child: Row(
              children: [
                for (final (i, l) in const [
                  (0, 'Live call'),
                  (1, 'Tickets'),
                  (2, 'WhatsApp'),
                  (3, 'Setup'),
                ].indexed)
                  Expanded(child: _navBtn(i, l.$2)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _navBtn(int i, String label) {
    final on = state.tab == i;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Material(
        color: on ? yellowDim : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => state.go(i),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  color: on ? yellow : muted,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =====================================================================
//  UI helpers
// =====================================================================
Widget header(String kicker, String title, [String sub = '']) => Padding(
  padding: const EdgeInsets.only(bottom: 14, top: 4),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        kicker,
        style: const TextStyle(
          color: yellow,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.4,
          fontSize: 12,
        ),
      ),
      const SizedBox(height: 2),
      Text(
        title,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 26,
          fontWeight: FontWeight.w800,
        ),
      ),
      if (sub.isNotEmpty)
        Text(sub, style: const TextStyle(color: muted, fontSize: 14)),
    ],
  ),
);

Widget box({
  required Widget child,
  Color color = card,
  Color borderColor = border,
  EdgeInsets? padding,
}) => Container(
  width: double.infinity,
  padding: padding ?? const EdgeInsets.all(16),
  decoration: BoxDecoration(
    color: color,
    borderRadius: BorderRadius.circular(18),
    border: Border.all(color: borderColor),
  ),
  child: child,
);

Widget bigBtn(
  String text,
  VoidCallback? onTap, {
  Color color = yellow,
  Color fg = dark,
  double height = 54,
  double fontSize = 16,
}) => SizedBox(
  height: height,
  width: double.infinity,
  child: ElevatedButton(
    style: ElevatedButton.styleFrom(
      backgroundColor: color,
      foregroundColor: fg,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    onPressed: onTap,
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(fontWeight: FontWeight.w800, fontSize: fontSize),
    ),
  ),
);

Widget label(String t) => Padding(
  padding: const EdgeInsets.only(top: 10, bottom: 6),
  child: Text(
    t,
    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
  ),
);

Widget field(TextEditingController c, String hint, {bool multiline = false}) =>
    TextField(
      controller: c,
      maxLines: multiline ? 4 : 1,
      minLines: multiline ? 3 : 1,
      style: const TextStyle(color: Colors.white, fontSize: 15),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: muted),
        filled: true,
        fillColor: inputBg,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
      ),
    );

ListView page(List<Widget> children) =>
    ListView(padding: const EdgeInsets.all(16), children: children);

// =====================================================================
//  Yellow swipe button
// =====================================================================
class SwipeButton extends StatefulWidget {
  const SwipeButton({
    super.key,
    required this.onDone,
    this.text = 'SWIPE TO ANSWER BOT  >>>',
  });
  final VoidCallback onDone;
  final String text;

  @override
  State<SwipeButton> createState() => _SwipeButtonState();
}

class _SwipeButtonState extends State<SwipeButton> {
  double p = 0; // 0..1

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        const h = 64.0, knob = 54.0;
        final max = c.maxWidth - knob - 10;
        return GestureDetector(
          onHorizontalDragUpdate: (d) =>
              setState(() => p = (p + d.delta.dx / max).clamp(0.0, 1.0)),
          onHorizontalDragEnd: (_) {
            if (p > 0.8) {
              setState(() => p = 0);
              widget.onDone();
            } else {
              setState(() => p = 0);
            }
          },
          child: Container(
            height: h,
            decoration: BoxDecoration(
              color: yellow,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  left: knob + 12,
                  child: Center(
                    child: Opacity(
                      opacity: 1 - p * 0.8,
                      child: Text(
                        widget.text,
                        style: const TextStyle(
                          color: dark,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.1,
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 5 + p * max,
                  top: 5,
                  child: Container(
                    width: knob,
                    height: knob,
                    decoration: BoxDecoration(
                      color: dark,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.arrow_forward,
                      color: yellow,
                      size: 28,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// =====================================================================
//  Live call page
// =====================================================================
class CallPage extends StatelessWidget {
  const CallPage({super.key, required this.s});
  final AppState s;

  @override
  Widget build(BuildContext context) {
    switch (s.mode) {
      case Mode.ringing:
        return _ringing();
      case Mode.bot:
      case Mode.done:
        return _bot();
      case Mode.idle:
        return _idle();
    }
  }

  Widget _idle() => page([
    header(
      'IRA SERVICE DESK',
      'Incoming call control',
      'Lower Parel field support',
    ),
    box(
      padding: const EdgeInsets.all(18),
      child: Column(
        children: [
          Container(
            width: 90,
            height: 90,
            decoration: const BoxDecoration(
              color: yellow,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.call, color: dark, size: 42),
          ),
          const SizedBox(height: 14),
          const Text(
            'Waiting for incoming call',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isAndroid
                ? 'Call aate hi yahan Green / Red ke saath YELLOW button aayega. Yellow swipe = voicebot call uthayega.'
                : 'Demo mode: neeche number daal ke test karo.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: muted),
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: label('Demo: customer number'),
          ),
          field(s.demoNumberCtl, '+91 98XXXXXXXX'),
          const SizedBox(height: 14),
          bigBtn(
            'Demo incoming call',
            () => s.showRinging(s.demoNumberCtl.text.trim(), real: false),
          ),
        ],
      ),
    ),
  ]);

  Widget _ringing() => page([
    header('IRA SERVICE DESK', 'Incoming call', 'Lower Parel field support'),
    box(
      borderColor: yellow,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'INCOMING CALL${s.real ? '' : '  (DEMO)'}',
            style: const TextStyle(
              color: yellow,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.4,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            s.caller.isEmpty ? 'Unknown number' : s.caller,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: bigBtn(
                  'Decline',
                  s.decline,
                  color: red,
                  fg: Colors.white,
                  height: 64,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: bigBtn(
                  'Answer',
                  s.answerSelf,
                  color: green,
                  fg: Colors.white,
                  height: 64,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text(
            'Khud baat karni hai toh GREEN. Voicebot se baat karwani hai toh YELLOW swipe karo:',
            style: TextStyle(color: Colors.white),
          ),
          const SizedBox(height: 12),
          SwipeButton(onDone: s.startBot),
        ],
      ),
    ),
  ]);

  Widget _bot() => page([
    header(
      'VOICE BOT ACTIVE',
      'Call screening',
      'Bot customer se baat kar raha hai',
    ),
    box(
      color: yellowDim,
      borderColor: yellow,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  s.stateText,
                  style: const TextStyle(
                    color: yellowTxt,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
              ),
              Text(
                '${(s.seconds ~/ 60).toString().padLeft(2, '0')}:${(s.seconds % 60).toString().padLeft(2, '0')}',
                style: const TextStyle(
                  color: yellowTxt,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            s.questionText,
            style: const TextStyle(color: Colors.white, fontSize: 17),
          ),
          const SizedBox(height: 8),
          Text(
            s.heardText,
            style: const TextStyle(color: yellowTxt, fontSize: 13),
          ),
        ],
      ),
    ),
    const SizedBox(height: 12),
    Row(
      children: [
        Expanded(
          child: bigBtn(
            'Repeat',
            s.mode == Mode.bot ? () => s.ask() : null,
            height: 48,
            fontSize: 14,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: bigBtn(
            'Mic (sun)',
            s.mode == Mode.bot ? () => s.listen() : null,
            height: 48,
            fontSize: 14,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: bigBtn(
            'Next >',
            s.mode == Mode.bot ? s.nextQ : null,
            height: 48,
            fontSize: 14,
          ),
        ),
      ],
    ),
    if (s.real)
      const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text(
          'Customer ki awaaz speaker pe aayegi. Mic na pakde toh jawab sunke yahan type karo aur Next dabao.',
          style: TextStyle(color: muted, fontSize: 13),
        ),
      ),
    for (final q in questions) ...[
      label(q.label),
      field(
        s.inputs[q.key]!,
        q.label,
        multiline: q.key == 'problem' || q.key == 'address',
      ),
    ],
    label('Caller number'),
    field(s.callerCtl, '+91'),
    const SizedBox(height: 16),
    bigBtn(
      'Create ticket now',
      s.mode == Mode.bot ? () => s.finish() : null,
      color: green,
      fg: Colors.white,
    ),
    TextButton(
      onPressed: s.mode == Mode.bot ? s.endWithoutTicket : null,
      child: const Text(
        'End call (no ticket)',
        style: TextStyle(color: red, fontWeight: FontWeight.w700),
      ),
    ),
  ]);
}

// =====================================================================
//  Tickets
// =====================================================================
class TicketsPage extends StatefulWidget {
  const TicketsPage({super.key, required this.s});
  final AppState s;

  @override
  State<TicketsPage> createState() => _TicketsPageState();
}

class _TicketsPageState extends State<TicketsPage> {
  bool showActive = true;

  @override
  Widget build(BuildContext context) {
    final st = widget.s.store;
    final act = st.active, done = st.completed;
    final items = showActive ? act : done;
    return page([
      header('IRA SERVICE DESK', 'Tickets'),
      Row(
        children: [
          Expanded(
            child: bigBtn(
              'Active (${act.length})',
              () => setState(() => showActive = true),
              color: showActive ? yellow : card,
              fg: showActive ? dark : muted,
              height: 48,
              fontSize: 14,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: bigBtn(
              'Completed (${done.length})',
              () => setState(() => showActive = false),
              color: !showActive ? yellow : card,
              fg: !showActive ? dark : muted,
              height: 48,
              fontSize: 14,
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      if (items.isEmpty)
        const Padding(
          padding: EdgeInsets.all(40),
          child: Center(
            child: Text('Koi ticket nahi hai', style: TextStyle(color: muted)),
          ),
        ),
      for (final t in items)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () => widget.s.openTicket(t.id),
            child: box(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '#${t.id}',
                          style: const TextStyle(
                            color: yellow,
                            fontWeight: FontWeight.w800,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      Text(
                        statusLabel[t.status]!,
                        style: TextStyle(
                          color: statusColor[t.status],
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    t.roName.isEmpty ? '(RO name nahi)' : t.roName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    t.problem.isEmpty ? '-' : t.problem,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: muted),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    fmtTime(t.createdAt) +
                        (t.daysLeft() != null
                            ? '   |   ${t.daysLeft()} din mein clear'
                            : ''),
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
    ]);
  }
}

class DetailPage extends StatelessWidget {
  const DetailPage({super.key, required this.s, required this.id});
  final AppState s;
  final String id;

  @override
  Widget build(BuildContext context) {
    final t = s.store.get(id);
    if (t == null) {
      return page([
        const Text('Ticket nahi mila', style: TextStyle(color: muted)),
      ]);
    }
    Widget row(String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            k,
            style: const TextStyle(
              color: muted,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
          Text(
            v.isEmpty ? '-' : v,
            style: const TextStyle(color: Colors.white, fontSize: 15),
          ),
        ],
      ),
    );
    final dl = t.daysLeft();
    return page([
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: () {
            s.openTicketId = null;
            s.go(1);
          },
          child: const Text(
            '<  All tickets',
            style: TextStyle(color: yellow, fontWeight: FontWeight.w800),
          ),
        ),
      ),
      header(
        'TICKET #${t.id}',
        t.roName.isEmpty ? '(RO name nahi)' : t.roName,
        t.location,
      ),
      box(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            row('ADDRESS', t.address),
            row('LOCATION', t.location),
            row('CALLER NUMBER', t.callerNumber),
            row('RECEIVED', fmtTime(t.createdAt)),
            row('ACTUAL PROBLEM', t.problem),
          ],
        ),
      ),
      const SizedBox(height: 18),
      const Text(
        'Ticket stage (manual update)',
        style: TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.w800,
        ),
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          for (final k in statuses) ...[
            Expanded(
              child: bigBtn(
                statusLabel[k]!,
                () => s.setStatus(t, k),
                color: t.status == k ? yellow : card,
                fg: t.status == k ? dark : muted,
                height: 50,
                fontSize: 14,
              ),
            ),
            if (k != statuses.last) const SizedBox(width: 8),
          ],
        ],
      ),
      if (dl != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'Completed - ye ticket $dl din mein auto-clear hoga',
            style: const TextStyle(color: green),
          ),
        ),
      const SizedBox(height: 14),
      Text(
        t.photosReceived
            ? 'Photos/videos: RECEIVED'
            : 'Photos/videos: abhi nahi aaye',
        style: TextStyle(
          color: t.photosReceived ? green : yellowTxt,
          fontWeight: FontWeight.w800,
          fontSize: 15,
        ),
      ),
      const SizedBox(height: 8),
      bigBtn(
        t.photosReceived ? 'Mark photos NOT received' : 'Mark photos received',
        () => s.togglePhotos(t),
        color: card,
        fg: Colors.white,
        height: 46,
        fontSize: 14,
      ),
      if (t.whatsappSent > 0)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            'WhatsApp reminder bheje: ${t.whatsappSent}',
            style: const TextStyle(color: muted),
          ),
        ),
      const SizedBox(height: 10),
      bigBtn(
        'Send WhatsApp: photos bhejo',
        () => s.sendWhatsapp(t),
        color: green,
        fg: Colors.white,
      ),
      const SizedBox(height: 10),
      bigBtn(
        'Call back customer',
        () => s.callBack(t),
        color: card,
        fg: yellow,
      ),
      const SizedBox(height: 10),
      bigBtn(
        'Delete ticket',
        () => s.deleteTicket(t),
        color: card,
        fg: red,
        height: 46,
      ),
    ]);
  }
}

// =====================================================================
//  WhatsApp config
// =====================================================================
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.s});
  final AppState s;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const fields = [
    ('company_name', 'Company name', false),
    ('default_country_code', 'Country code (10 digit number ke aage)', false),
    ('whatsapp_message', 'Message template', true),
    ('cloud_api_phone_number_id', 'Cloud API: Phone number ID', false),
    ('cloud_api_token', 'Cloud API: Access token', false),
    ('tts_language', 'Bot voice language (en-IN / hi-IN)', false),
    ('stt_language', 'Sunne ki language (en_IN / hi_IN)', false),
    ('voice_pitch', 'Awaaz pitch (0.7 = male, 1.0 = female)', false),
    ('voice_rate', 'Bolne ki speed (0.3 slow - 0.6 fast)', false),
  ];
  late final Map<String, TextEditingController> c = {
    for (final f in fields)
      f.$1: TextEditingController(text: widget.s.store.cfg(f.$1)),
  };
  late String mode = widget.s.store.cfg('whatsapp_mode');

  @override
  Widget build(BuildContext context) {
    Widget modeBtn(String k, String l) => Expanded(
      child: bigBtn(
        l,
        () => setState(() => mode = k),
        color: mode == k ? yellow : card,
        fg: mode == k ? dark : muted,
        height: 48,
        fontSize: 13,
      ),
    );
    return page([
      header(
        'CONFIG',
        'WhatsApp settings',
        'Client yahan apna message set kare',
      ),
      label(fields[0].$2),
      field(c[fields[0].$1]!, fields[0].$2),
      label('WhatsApp mode'),
      Row(
        children: [
          modeBtn('link', 'WhatsApp app (free)'),
          const SizedBox(width: 8),
          modeBtn('cloud_api', 'Cloud API (auto)'),
        ],
      ),
      for (final f in fields.skip(1)) ...[
        label(f.$2),
        field(c[f.$1]!, f.$2, multiline: f.$3),
      ],
      const Padding(
        padding: EdgeInsets.only(top: 6),
        child: Text(
          'Placeholders: {ro_name} {company} {ticket_id} {problem} {location} {address}',
          style: TextStyle(color: muted, fontSize: 12),
        ),
      ),
      const SizedBox(height: 14),
      bigBtn(
        'Save',
        () => widget.s.saveConfig({
          for (final e in c.entries) e.key: e.value.text.trim(),
          'whatsapp_mode': mode,
        }),
      ),
      const SizedBox(height: 10),
      const Text(
        'Completed tickets $purgeDays din baad automatic clear hote hain.',
        style: TextStyle(color: muted),
      ),
    ]);
  }
}

// =====================================================================
//  Setup (asli call ke liye permissions)
// =====================================================================
class SetupPage extends StatefulWidget {
  const SetupPage({super.key, required this.s});
  final AppState s;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  bool phoneOk = !isAndroid, overlayOk = !isAndroid;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (!isAndroid) return;
    final p =
        await Permission.phone.isGranted &&
        await Permission.microphone.isGranted;
    final o = await Permission.systemAlertWindow.isGranted;
    if (mounted) {
      setState(() {
        phoneOk = p;
        overlayOk = o;
      });
    }
  }

  Future<void> _askPerms() async {
    await [
      Permission.phone,
      Permission.microphone,
      Permission.notification,
    ].request();
    await _refresh();
  }

  Future<void> _askOverlay() async {
    await Permission.systemAlertWindow.request();
    await _refresh();
  }

  Widget step(
    int n,
    bool ok,
    String title,
    String sub,
    String btn,
    VoidCallback onTap,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: box(
      borderColor: ok ? green : border,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${ok ? 'OK' : 'STEP $n'}  $title',
            style: TextStyle(
              color: ok ? green : yellow,
              fontWeight: FontWeight.w800,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 6),
          Text(sub, style: const TextStyle(color: muted, fontSize: 13)),
          const SizedBox(height: 10),
          bigBtn(
            btn,
            onTap,
            color: ok ? card : yellow,
            fg: ok ? muted : dark,
            height: 46,
            fontSize: 14,
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => page([
    header('SETUP', 'Asli call setup', 'Ek baar ye 3 step karo'),
    step(
      1,
      phoneOk,
      'Phone + mic permission',
      'Call pehchanne, uthane/kaatne aur sunne ke liye.',
      'Permission do',
      _askPerms,
    ),
    step(
      2,
      overlayOk,
      'Display over other apps',
      'Isse call screen ke upar yellow button wala app khulega. List mein IRA Service Desk ON karo.',
      'Settings kholo',
      _askOverlay,
    ),
    step(
      3,
      false,
      'Xiaomi / Redmi / Poco ke liye',
      "App info > Autostart ON, Other permissions > 'Display pop-up windows while running in background' + "
          "'Show on Lock screen' Allow, Battery saver > No restrictions.",
      'App info kholo',
      () => openAppSettings(),
    ),
    const Text(
      'Note: Android kisi app ko call ke andar awaaz daalne nahi deta, isliye bot SPEAKER se bolta hai aur '
      'customer ko phone ke mic se sunai deta hai. Phone shaant jagah rakho.',
      style: TextStyle(color: muted, fontSize: 13),
    ),
    if (kDebugMode) const SizedBox(height: 8),
  ]);
}

// =====================================================================
//  Error screen (crash ki jagah)
// =====================================================================
class ErrorScreen extends StatelessWidget {
  const ErrorScreen({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    color: bg,
    padding: const EdgeInsets.all(16),
    child: SingleChildScrollView(
      child: Text(
        'App mein error aaya - is screen ka screenshot Claude ko bhejo\n\n$text',
        textDirection: TextDirection.ltr,
        style: const TextStyle(color: Colors.white, fontSize: 12),
      ),
    ),
  );
}
