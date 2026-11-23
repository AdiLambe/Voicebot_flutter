// IRA Voicebot - core logic: tickets, storage, 20-din auto-clear, WhatsApp.
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// ---------------- Voicebot script ----------------
class Question {
  final String key, label, text;
  const Question(this.key, this.label, this.text);
}

const questions = [
  Question('ro_name', 'RO name', 'Hello sir, aapka RO naam bataiye.'),
  Question('address', 'Address', 'Apna address bataiye.'),
  Question(
    'location',
    'Location',
    'Aap kaunsi location se baat kar rahe hain?',
  ),
  Question(
    'problem',
    'Actual problem',
    'Actual problem kya hai, detail mein bataiye.',
  ),
];

const sorryMessage =
    'Maaf kijiye sir, samajh nahi aaya. Kripya dobara bataiye.';
// Last message - hard coded
const finalMessage =
    'Please aapki machine ke photos ya videos WhatsApp par bhej dijiye. '
    'Aapka ticket ban gaya hai. Dhanyavaad.';

const statuses = ['open', 'in_progress', 'completed'];
const statusLabel = {
  'open': 'Open',
  'in_progress': 'In progress',
  'completed': 'Completed',
};
const purgeDays = 20; // completed tickets 20 din baad auto-delete
const _day = Duration(days: 1);

const defaultConfig = <String, String>{
  'company_name': 'IRA - Instrument Research Associates',
  // link = WhatsApp app khulega message ready (free) | cloud_api = Meta Cloud API se direct
  'whatsapp_mode': 'link',
  'default_country_code': '91',
  'whatsapp_message':
      'Namaste {ro_name}, {company} se. Ticket #{ticket_id} ({problem}). '
      'Kripya apni machine ke photos/videos is WhatsApp par bhej dijiye. Dhanyavaad.',
  'cloud_api_token': '',
  'cloud_api_phone_number_id': '',
  'tts_language': 'en-IN',
  'stt_language': 'en_IN',
  'voice_pitch': '0.7', // 0.7 = male awaaz, 1.0 = normal
  'voice_rate': '0.45',
};

class Ticket {
  String id, roName, address, location, problem, callerNumber, status;
  bool photosReceived;
  int whatsappSent;
  DateTime createdAt, updatedAt;
  DateTime? completedAt;
  List<Map<String, dynamic>> history;

  Ticket({
    required this.id,
    required this.roName,
    required this.address,
    required this.location,
    required this.problem,
    required this.callerNumber,
    this.status = 'open',
    this.photosReceived = false,
    this.whatsappSent = 0,
    required this.createdAt,
    required this.updatedAt,
    this.completedAt,
    List<Map<String, dynamic>>? history,
  }) : history = history ?? [];

  Map<String, dynamic> toJson() => {
    'id': id,
    'ro_name': roName,
    'address': address,
    'location': location,
    'problem': problem,
    'caller_number': callerNumber,
    'status': status,
    'photos_received': photosReceived,
    'whatsapp_sent': whatsappSent,
    'created_at': createdAt.millisecondsSinceEpoch,
    'updated_at': updatedAt.millisecondsSinceEpoch,
    'completed_at': completedAt?.millisecondsSinceEpoch,
    'history': history,
  };

  static Ticket fromJson(Map<String, dynamic> j) => Ticket(
    id: j['id'],
    roName: j['ro_name'] ?? '',
    address: j['address'] ?? '',
    location: j['location'] ?? '',
    problem: j['problem'] ?? '',
    callerNumber: j['caller_number'] ?? '',
    status: j['status'] ?? 'open',
    photosReceived: j['photos_received'] ?? false,
    whatsappSent: j['whatsapp_sent'] ?? 0,
    createdAt: DateTime.fromMillisecondsSinceEpoch(j['created_at']),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(j['updated_at']),
    completedAt: j['completed_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(j['completed_at']),
    history: (j['history'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e))
        .toList(),
  );

  /// Completed ticket kitne din mein clear hoga (null = completed nahi hai)
  int? daysLeft([DateTime? now]) {
    if (status != 'completed' || completedAt == null) return null;
    final passed = (now ?? DateTime.now()).difference(completedAt!).inDays;
    return (purgeDays - passed).clamp(0, purgeDays);
  }
}

class Store {
  static const _kTickets = 'ira_tickets_v1';
  static const _kConfig = 'ira_config_v1';
  static const _kLastId = 'ira_last_id';

  final SharedPreferences prefs;
  List<Ticket> tickets = [];
  Map<String, String> config = Map.of(defaultConfig);

  Store._(this.prefs);

  static Future<Store> open() async {
    final s = Store._(await SharedPreferences.getInstance());
    final raw = s.prefs.getString(_kTickets);
    if (raw != null) {
      try {
        s.tickets = (jsonDecode(raw) as List)
            .map((e) => Ticket.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      } catch (_) {}
    }
    final cfg = s.prefs.getString(_kConfig);
    if (cfg != null) {
      try {
        (jsonDecode(cfg) as Map).forEach(
          (k, v) => s.config[k.toString()] = v.toString(),
        );
      } catch (_) {}
    }
    await s.purgeCompleted();
    return s;
  }

  Future<void> save() => prefs.setString(
    _kTickets,
    jsonEncode(tickets.map((t) => t.toJson()).toList()),
  );
  Future<void> saveConfig() => prefs.setString(_kConfig, jsonEncode(config));

  String cfg(String k) => config[k] ?? defaultConfig[k] ?? '';

  Future<Ticket> createTicket(
    Map<String, String> answers,
    String callerNumber,
  ) async {
    final next = (prefs.getInt(_kLastId) ?? 0) + 1;
    await prefs.setInt(_kLastId, next);
    final now = DateTime.now();
    final t = Ticket(
      id: 'IRA-${next.toString().padLeft(4, '0')}',
      roName: (answers['ro_name'] ?? '').trim(),
      address: (answers['address'] ?? '').trim(),
      location: (answers['location'] ?? '').trim(),
      problem: (answers['problem'] ?? '').trim(),
      callerNumber: callerNumber.trim(),
      createdAt: now,
      updatedAt: now,
      history: [
        {'status': 'open', 'at': now.millisecondsSinceEpoch},
      ],
    );
    tickets.insert(0, t);
    await save();
    return t;
  }

  Ticket? get(String id) {
    for (final t in tickets) {
      if (t.id == id) return t;
    }
    return null;
  }

  Future<void> setStatus(String id, String status) async {
    final t = get(id);
    if (t == null || t.status == status) return;
    final now = DateTime.now();
    t.status = status;
    t.completedAt = status == 'completed' ? now : null;
    t.history.add({'status': status, 'at': now.millisecondsSinceEpoch});
    t.updatedAt = now;
    await save();
  }

  Future<void> touch(Ticket t) async {
    t.updatedAt = DateTime.now();
    await save();
  }

  Future<void> delete(String id) async {
    tickets.removeWhere((t) => t.id == id);
    await save();
  }

  List<Ticket> get active =>
      tickets.where((t) => t.status != 'completed').toList();
  List<Ticket> get completed =>
      tickets.where((t) => t.status == 'completed').toList();

  /// Completed tickets jo 20 din se purane hain, delete. Kitne delete hue wo return.
  Future<int> purgeCompleted([DateTime? now]) async {
    now ??= DateTime.now();
    final before = tickets.length;
    tickets.removeWhere(
      (t) =>
          t.status == 'completed' &&
          t.completedAt != null &&
          now!.difference(t.completedAt!) > _day * purgeDays,
    );
    final removed = before - tickets.length;
    if (removed > 0) await save();
    return removed;
  }

  // ---------- WhatsApp ----------
  String normalizeNumber(String n) {
    var d = n.replaceAll(RegExp(r'[^0-9]'), '');
    if (d.length == 10) d = cfg('default_country_code') + d;
    return d;
  }

  String whatsappText(Ticket t) =>
      cfg('whatsapp_message')
          .replaceAll('{ro_name}', t.roName.isEmpty ? 'Sir' : t.roName)
          .replaceAll('{company}', cfg('company_name'))
          .replaceAll('{ticket_id}', t.id)
          .replaceAll('{problem}', t.problem)
          .replaceAll('{location}', t.location)
          .replaceAll('{address}', t.address);

  Uri whatsappLink(Ticket t) => Uri.parse(
    'https://wa.me/${normalizeNumber(t.callerNumber)}?text=${Uri.encodeComponent(whatsappText(t))}',
  );

  /// Meta WhatsApp Cloud API se direct message. (ok, message)
  Future<(bool, String)> sendWhatsappCloud(Ticket t) async {
    final token = cfg('cloud_api_token').trim();
    final pid = cfg('cloud_api_phone_number_id').trim();
    if (token.isEmpty || pid.isEmpty) {
      return (false, 'Cloud API token / phone number ID config mein nahi hai');
    }
    try {
      final r = await http.post(
        Uri.parse('https://graph.facebook.com/v20.0/$pid/messages'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'messaging_product': 'whatsapp',
          'to': normalizeNumber(t.callerNumber),
          'type': 'text',
          'text': {'body': whatsappText(t)},
        }),
      );
      if (r.statusCode >= 200 && r.statusCode < 300) {
        return (true, 'WhatsApp message bhej diya');
      }
      return (false, 'Send fail: ${r.statusCode} ${r.body}');
    } catch (e) {
      return (false, 'Send fail: $e');
    }
  }
}

String fmtTime(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '${two(t.day)}/${two(t.month)}/${t.year} ${two(h)}:${two(t.minute)} ${t.hour < 12 ? 'AM' : 'PM'}';
}
